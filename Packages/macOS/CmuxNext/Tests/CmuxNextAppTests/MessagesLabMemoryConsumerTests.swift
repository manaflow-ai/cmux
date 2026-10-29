import AppKit
import CmuxNextCompat
import CmuxNextDesign
@testable import CmuxNextHome
import CmuxNextWakeups
@testable import MessagesLabHome
@testable import MessagesLabSidebar
import Testing

/// The Home transcript's shared pixel caches (row bitmaps 160 MB, media 96 MB, tiles 48 MB) and
/// the Home lists' bitmaps (40 MB each) had fixed sizes outside the memory coordinator. Now they are one lossless
/// consumer on one budget: the limit scales the caps, a release trims to them, limit 0 holds 0 bytes, and once
/// no Home view has shown for 60 s one background deadline empties them; a Home view that shows gives the
/// budget back.
@MainActor @Suite(.serialized) struct MessagesLabMemoryConsumerTests {
    /// A registry that hands each new consumer `limit` at once, as the coordinator does.
    @MainActor private final class FakeRegistry: MemoryConsumerRegistry {
        var limit = MemoryLimit.default
        var entries: [MemoryConsumerEntry] = []

        func addMemoryConsumer(_ entry: MemoryConsumerEntry) {
            entries.append(entry)
            entry.liveConsumer?.updateMemoryLimit(limit)
        }
    }

    /// Four times what ``fill()`` stores (18 bitmaps of 32 x 32 px), so every cap holds a full fill and 1 % of
    /// the limit is a few bitmaps.
    private static let budget = 18 * 4_096 * 4

    private let rig = MainDeadlineRig()
    private let registry = FakeRegistry()
    private let rows = RowBitmaps()
    private let media = MediaCache()
    private let tiles = TileCache()

    private func consumer() -> MessagesLabMemoryConsumer {
        MessagesLabMemoryConsumer(
            budgetBytes: Self.budget, registry: registry,
            idle: MainDeadline(owner: "test.home.labCaches.idle", workClass: .background, scheduler: rig.deadlines),
            caches: MessagesLabTranscriptCaches(rows: rows, media: media, tiles: tiles, ownsSlices: false))
    }

    private static func image() throws -> CGImage {
        try #require(WideBitmap.make(size: CGSize(width: 16, height: 16), scale: 2, opaque: false) { ctx in
            ctx.setFillColor(CGColor(gray: 0.5, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
        })
    }

    /// Six row bitmaps, decoded images and tiles in the caches.
    private func fill() throws {
        let image = try Self.image()
        for n in 0..<6 {
            let spec = RowSpec(key: "sep:consumer-\(n)", kind: .separator(bold: "Today", rest: "9:\(10 + n) AM"), gap: 8, height: 14)
            rows.insert([(spec, image)], scale: 2)
            media.store("photo\(n).png@2.0", UIImage(cgImage: image, scale: 2))
            tiles.put(TileCache.Key(lineage: n, start: 0, end: 10, final: true, column: 300, chunk: 0, outgoing: false,
                                    scale: 2, palette: 0), image)
        }
    }

    private static func slice(_ percent: Int) -> MemoryReleaseSlice {
        MemoryReleaseSlice(limit: MemoryLimit(percent: percent)) { false }
    }

    @Test func itRegistersOnceAsALosslessCheapConsumerAtTheCurrentLimit() {
        registry.limit = MemoryLimit(percent: 50)
        let caches = consumer()
        #expect(registry.entries.count == 1)
        #expect(registry.entries.first?.name == MessagesLabMemoryConsumer.memoryConsumerName)
        let traits = MessagesLabMemoryConsumer.memoryTraits
        #expect(traits.isManaged && traits.retention == .lossless && traits.dataAccess == .none && traits.recreateCost == .cheap)
        #expect(caches.limit == MemoryLimit(percent: 50))
        #expect(caches.allowedBytes == Self.budget / 2)
        let share = MessagesLabTranscriptCaches.shares(of: Self.budget / 2 - Self.budget / 2 / 9)
        #expect(rows.byteBudget == share.rows, "the row cap is not its share of the scaled budget")
        #expect(tiles.budget == share.tiles)
    }

    @Test func aReleaseTrimsToTheLimitAndLimitZeroHoldsNothing() throws {
        let caches = consumer()
        try fill()
        let full = caches.memoryBytes
        try #require(full > 0 && caches.memoryUsage?.footprintBytes == full)

        // The slice's limit allows half of what the caches hold.
        let half = Int((Double(full) / 2 / Double(Self.budget) * 100).rounded(.up))
        _ = caches.releaseMemory(within: Self.slice(half))
        #expect(caches.memoryBytes <= caches.allowedBytes, "a release left more than the limit allows")
        #expect(caches.memoryBytes > 0)

        #expect(caches.releaseMemory(within: Self.slice(0)) == .done)
        #expect(caches.memoryBytes == 0)
        #expect(rows.bytes == 0 && media.bytes == 0 && tiles.bytes == 0)
        try fill()
        #expect(caches.memoryBytes == 0, "the caches kept bitmaps at limit 0")

        caches.updateMemoryLimit(.default)
        try fill()
        #expect(caches.memoryBytes == full, "the caches did not fill again once the limit rose")
    }

    @Test func noHomeViewShownForSixtySecondsEmptiesTheCachesOnce() throws {
        let caches = consumer()
        let home = VisibilityNode(root: "test.home", own: .visible)
        caches.track(home)
        try fill()
        let full = caches.memoryBytes
        #expect(!rig.hasArmedWake, "a shown Home armed the idle deadline")

        home.set(.hidden)
        #expect(rig.hasArmedWake)
        rig.advance(by: .seconds(59))
        rig.fireAtNow()
        #expect(!caches.isIdle && caches.memoryBytes == full, "the caches emptied before 60 s")

        rig.fireAndRun()
        #expect(caches.isIdle)
        #expect(caches.memoryBytes == 0)
        #expect(caches.allowedBytes == 0)
        #expect(!rig.hasArmedWake, "the idle deadline repeats")
        try fill()
        #expect(caches.memoryBytes == 0, "an idle Home kept bitmaps")

        home.set(.visible)
        #expect(!caches.isIdle)
        #expect(caches.allowedBytes == Self.budget)
        try fill()
        #expect(caches.memoryBytes == full, "the shown Home did not get its budget back")
    }

    @Test func aHomeViewThatShowsBeforeTheDeadlineKeepsTheCaches() throws {
        let caches = consumer()
        let home = VisibilityNode(root: "test.home", own: .visible)
        caches.track(home)
        try fill()
        let full = caches.memoryBytes

        home.set(.hidden)
        rig.advance(by: .seconds(30))
        home.set(.visible)
        #expect(!rig.hasArmedWake, "showing again left the idle deadline armed")
        rig.advance(by: .seconds(60))
        rig.fireAtNow()
        #expect(!caches.isIdle && caches.memoryBytes == full)
    }

    /// The Home page stays in its window while the window is covered, miniaturized or in a hidden app (Cmd-H).
    /// Before, the split counted its own root node, visible whenever it was in a window and not hidden, so the
    /// idle deadline never armed and the caches kept their whole budget. Now the page's node, under its
    /// window's (`ViewVisibility`, as `TopHomePageView` passes it), is the one tracked.
    @Test func aCoveredOrMiniaturizedWindowEmptiesTheCachesThoughTheHomePageStaysInIt() throws {
        _ = NSApplication.shared
        let caches = consumer()
        let page = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let pageVisibility = ViewVisibility("test.topHome")
        let split = HomeSidebarSplitView(sidebar: HomeSidebarView(), content: NSView(), mainWork: linklessMainWork(),
                                         caches: caches, page: pageVisibility.node)
        split.frame = page.bounds
        page.addSubview(split)
        let window = NSWindow(contentRect: page.frame, styleMask: [.borderless], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let source = WindowVisibilitySource.of(window, read: { _ in .visible })
        window.contentView = page
        pageVisibility.place(in: window)
        try fill()
        #expect(caches.memoryBytes > 0)
        #expect(!rig.hasArmedWake, "a shown Home page armed the idle deadline")

        source.node.set(.occluded)
        #expect(split.window === window && !split.isHiddenOrHasHiddenAncestor)
        #expect(rig.hasArmedWake, "a covered window's Home page still counts as shown")
        rig.fireAndRun()
        #expect(caches.isIdle && caches.memoryBytes == 0, "the caches kept \(caches.memoryBytes) bytes in a covered window")

        source.node.set(.visible)
        #expect(!caches.isIdle && !rig.hasArmedWake)
        try fill()
        #expect(caches.memoryBytes > 0 && caches.allowedBytes == Self.budget, "the shown Home page did not get its budget back")

        source.node.set(.hidden)
        #expect(rig.hasArmedWake, "a miniaturized window's Home page still counts as shown")
        rig.fireAndRun()
        #expect(caches.isIdle && caches.memoryBytes == 0)
    }

    @Test func eachHomeListGetsItsShareAndTrimsWithTheCaches() throws {
        let caches = consumer()
        let sidebar = HomeSidebarView()
        caches.track(sidebar: sidebar)
        let list = sidebar.list
        #expect(list.controller.cache.budget == Self.budget / 9)

        let image = try Self.image()
        list.controller.cache.insert(SidebarBitmapKey(kind: .row, id: "c1", version: 1, width: 300, emphasized: false, generation: 0), image)
        #expect(caches.memoryBytes == list.bitmapBytes)
        _ = caches.releaseMemory(within: Self.slice(0))
        #expect(list.bitmapBytes == 0)
        #expect(list.controller.cache.budget == 0)
    }
}
