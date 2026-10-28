import AppKit
import CmuxNextCompat
import CmuxNextFiles
import CmuxNextFilesUI
import CmuxNextWakeups
import CmuxNextWakeupsTestSupport
import Foundation
import Testing

/// The Files thumbnails were an `NSCache` with a count limit only, outside the
/// memory coordinator. Now they are one lossless consumer bounded by count and pixel bytes: a new
/// limit frees nothing, a release frees down to it least recently used first, the critical limit
/// keeps only the working set, and a thumbnail asked for after a release renders again.
@MainActor @Suite struct FileIconProviderMemoryTests {
    /// A registry that hands each new consumer `limit` at once, as the coordinator does.
    @MainActor private final class FakeRegistry: MemoryConsumerRegistry {
        var limit = MemoryLimit.default
        var entries: [MemoryConsumerEntry] = []

        func addMemoryConsumer(_ entry: MemoryConsumerEntry) {
            entries.append(entry)
            entry.liveConsumer?.updateMemoryLimit(limit)
        }
    }

    /// Counts renders and draws one 16 x 16 RGBA picture (1,024 pixel bytes).
    private nonisolated final class Renders: Sendable {
        private let renders = Mutex(0)

        var count: Int { renders.withLock { $0 } }

        var render: FileIconProvider.Render {
            { [self] _, _, _ in
                renders.withLock { $0 += 1 }
                let context = CGContext(data: nil, width: 16, height: 16, bitsPerComponent: 8, bytesPerRow: 64,
                                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
                return context?.makeImage()
            }
        }
    }

    private static func entry(_ index: Int) -> FileEntry {
        FileEntry(url: URL(fileURLWithPath: "/files/\(index).png"), kind: .file, size: 1,
                  modified: Date(timeIntervalSinceReferenceDate: 1))
    }

    private static func fill(_ icons: FileIconProvider, _ range: Range<Int>) async {
        for index in range { _ = await icons.thumbnail(for: entry(index), size: 16, scale: 1) }
    }

    private static func slice(_ limit: MemoryLimit) -> MemoryReleaseSlice {
        MemoryReleaseSlice(limit: limit) { false }
    }

    @Test func registeringTakesTheCurrentLimitAndANewLimitFreesNothing() async {
        let renders = Renders()
        let icons = FileIconProvider(thumbnailCount: 10, workingSet: 2, render: renders.render)
        await Self.fill(icons, 0..<10)
        let registry = FakeRegistry()
        registry.limit = MemoryLimit(percent: 50)
        icons.registerMemoryConsumer(with: registry)
        #expect(registry.entries.count == 1)
        #expect(icons.memoryUsage?.entries == 10)
        #expect(icons.releaseMemory(within: Self.slice(MemoryLimit(percent: 50))) == .done)
        #expect(icons.memoryUsage?.entries == 5)
        // Least recently used first: the newest stays.
        #expect(icons.cachedThumbnail(for: Self.entry(9), size: 16) != nil)
        #expect(icons.cachedThumbnail(for: Self.entry(0), size: 16) == nil)
    }

    @Test func theCriticalLimitKeepsTheWorkingSetAndATileAskedTwiceRendersOnce() async {
        let renders = Renders()
        let icons = FileIconProvider(thumbnailCount: 10, workingSet: 2, render: renders.render)
        await Self.fill(icons, 0..<4)
        _ = icons.icon(for: FileEntry(url: URL(fileURLWithPath: "/files/folder"), kind: .folder))
        // Critical: the two newest thumbnails stay; older ones and the type icons go.
        #expect(icons.releaseMemory(within: Self.slice(.criticalThreshold)) == .done)
        #expect(icons.memoryUsage == MemoryUsage(footprintBytes: 2 * 1_024, entries: 2))
        #expect(icons.cachedThumbnail(for: Self.entry(0), size: 16) == nil)
        // Still critical: a tile asked for twice renders once and is kept; the oldest kept one goes.
        _ = await icons.thumbnail(for: Self.entry(0), size: 16, scale: 1)
        #expect(await icons.thumbnail(for: Self.entry(0), size: 16, scale: 1) != nil)
        #expect(renders.count == 5)
        #expect(icons.memoryUsage?.entries == 2)
        #expect(icons.cachedThumbnail(for: Self.entry(3), size: 16) != nil)
        #expect(icons.cachedThumbnail(for: Self.entry(2), size: 16) == nil)
        // Back at the full limit, a released thumbnail renders once more and is kept.
        icons.updateMemoryLimit(.default)
        _ = await icons.thumbnail(for: Self.entry(1), size: 16, scale: 1)
        _ = await icons.thumbnail(for: Self.entry(1), size: 16, scale: 1)
        #expect(renders.count == 6)
        #expect(icons.memoryUsage?.entries == 3)
    }

    /// Package icons (one per app bundle) were kept with the type icons, unbounded and uncounted. Each is read on
    /// the system lane, so the test waits for the 300 to land.
    @Test func packageIconsAreCountBoundedCountedAndReleased() {
        let system = OpenWithWorkspace(apps: [], defaultApp: nil)
        let queries = WorkspaceQueries(work: BackgroundWork(label: "test.file-icons"), mainWork: .still(), system: system,
                                       capacity: 512)
        let icons = FileIconProvider(queries: queries, workingSet: 2)
        let packages = (0..<300).map { FileEntry(url: URL(fileURLWithPath: "/apps/\($0).app"), kind: .package) }
        for package in packages { _ = icons.icon(for: package) }
        let end = Date(timeIntervalSinceNow: 10)
        while icons.arrivals < packages.count, Date() < end {
            _ = RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01))
        }
        #expect(icons.arrivals == packages.count)
        #expect(system.mainAsks.withLock { $0 } == 0, "an icon was read on the main thread")
        // The provider is each package icon's one owner: the query table keeps none, so the provider's release frees them.
        #expect(queries.iconCount == 0)
        let usage = icons.memoryUsage
        #expect((usage?.entries ?? .max) <= FileIconProvider.defaultPackageIconCount)
        #expect(usage?.footprintBytes == (usage?.entries ?? 0) * FileIconProvider.iconBytes)
        // The newest is kept: asking again returns the same image without a new lookup.
        let newest = icons.icon(for: packages[299])
        #expect(icons.icon(for: packages[299]) === newest)
        #expect(icons.releaseMemory(within: Self.slice(.criticalThreshold)) == .done)
        #expect(icons.memoryUsage == MemoryUsage(footprintBytes: 2 * FileIconProvider.iconBytes, entries: 2))
        #expect(icons.icon(for: packages[299]) === newest)
    }

    /// The provider is never registered while `memoryFileHomeCaches` is off: its byte bound alone
    /// holds the thumbnails (the `NSCache` it replaced dropped them under system pressure).
    @Test func anUnregisteredProviderIsBoundedByPixelBytes() async {
        #expect(FileIconProvider().thumbnailByteLimit == FileIconProvider.defaultThumbnailBytes)
        let renders = Renders()
        // 1,024 bytes each: 8 KiB holds 8 of the 20 asked for.
        let icons = FileIconProvider(thumbnailCount: 100, thumbnailBytes: 8 << 10, workingSet: 0, render: renders.render)
        await Self.fill(icons, 0..<20)
        let usage = icons.memoryUsage
        #expect((usage?.footprintBytes ?? .max) <= 8 << 10)
        #expect((usage?.footprintBytes ?? 0) == (usage?.entries ?? 0) * 1_024)
        // An expired slice frees nothing and asks for another.
        let ended = MemoryReleaseSlice(limit: .criticalThreshold) { true }
        #expect(icons.releaseMemory(within: ended) == .more)
        #expect(icons.memoryUsage?.entries == usage?.entries)
    }
}
