import AppKit
import CmuxNextCompat
import CmuxNextPages
import CmuxNextSettings
import Foundation
import Testing
@testable import CmuxNextAgentPane
import CmuxNextWakeups

/// The agent pane's caches as memory consumers: the coordinator's limit scales what
/// each keeps, limit 0 keeps nothing, and what a release dropped is made again on the next ask.
@MainActor
struct AgentPaneMemoryConsumerTests {
    private static func slice(_ percent: Int) -> MemoryReleaseSlice {
        MemoryReleaseSlice(limit: MemoryLimit(percent: percent)) { false }
    }

    /// A page snapshot of `side` points, with one bitmap so its bytes count.
    private static func frame(_ side: Int) -> NSImage {
        let image = NSImage(size: NSSize(width: side, height: side))
        if let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8,
                                      samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                      bytesPerRow: 0, bitsPerPixel: 0) {
            image.addRepresentation(rep)
        }
        return image
    }

    private static func size(_ side: Int) -> CGSize { CGSize(width: side, height: side) }

    /// A registry that hands each new consumer `limit` at once, as the coordinator does.
    private final class FakeRegistry: MemoryConsumerRegistry {
        var limit = MemoryLimit.default
        var entries: [MemoryConsumerEntry] = []

        func addMemoryConsumer(_ entry: MemoryConsumerEntry) {
            entries.append(entry)
            entry.liveConsumer?.updateMemoryLimit(limit)
        }
    }

    // MARK: New Tab frames

    @Test func newTabFramesRegisterUnderTheirNameAndTakeTheCurrentLimit() {
        let registry = FakeRegistry()
        registry.limit = .criticalThreshold
        let frames = AgentPaneNewTabFrame()

        frames.registerMemoryConsumer(with: registry)
        frames.store(Self.frame(10), size: Self.size(10), appearance: nil, generation: 0)

        #expect(registry.entries.map(\.name) == ["agent-new-tab-frames"])
        #expect(registry.entries.first?.traits == AgentPaneNewTabFrame.memoryTraits)
        #expect(frames.frameCount == 0, "the limit the registry handed over at registration holds")
    }

    @Test func newTabFramesReleaseTheOldestDownToTheLimit() {
        let frames = AgentPaneNewTabFrame()
        for side in [10, 20, 30, 40] { frames.store(Self.frame(side), size: Self.size(side), appearance: nil, generation: 0) }
        #expect(frames.memoryUsage == MemoryUsage(footprintBytes: (100 + 400 + 900 + 1_600) * 4, entries: 4))

        #expect(frames.releaseMemory(within: Self.slice(50)) == .done)

        #expect(frames.frameCount == 2)
        #expect(frames.image(size: Self.size(10), appearance: nil) == nil)
        #expect(frames.image(size: Self.size(40), appearance: nil) != nil)
    }

    @Test func newTabFramesAtLimitZeroKeepNoneUntilTheLimitRises() {
        let frames = AgentPaneNewTabFrame()
        frames.store(Self.frame(10), size: Self.size(10), appearance: nil, generation: 0)

        frames.updateMemoryLimit(.criticalThreshold)
        #expect(frames.releaseMemory(within: Self.slice(0)) == .done)
        frames.store(Self.frame(20), size: Self.size(20), appearance: nil, generation: 0)
        #expect(frames.frameCount == 0)

        // The next capture after the limit comes back is kept again.
        frames.updateMemoryLimit(.default)
        frames.store(Self.frame(20), size: Self.size(20), appearance: nil, generation: 0)
        #expect(frames.image(size: Self.size(20), appearance: nil) != nil)
    }

    private actor NoHost: AgentPaneHostProviding {
        func handshake(sessionId: String?) async throws -> AgentPaneHandshake { throw AgentPaneHostError.daemonStopped }
    }

    /// An agent page inside a pane's content host.
    private static func page() throws -> (view: AgentPaneView, host: NSView) {
        let file = try #require(AgentPageTestRoot.page)
        let view = try #require(AgentPaneView(mainThread: .standalone(), model: AgentPaneModel(host: NoHost()), work: BackgroundWork(label: "test.agent-pane"), source: .bundled(file),
                                              webUI: .agentPaneTestHost(), gestures: .testing()))
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        host.addSubview(view)
        return (view, host)
    }

    /// At the critical limit a capture takes no snapshot: it never arms, so no settle timer, no page
    /// frame wait and no pane-sized bitmap that ``AgentPaneNewTabFrame/store(_:size:appearance:generation:)``
    /// would drop at once. At the full limit the same capture arms.
    @Test func aCaptureAtLimitZeroTakesNoSnapshot() throws {
        let page = try Self.page()
        let frames = AgentPaneNewTabFrame()

        frames.updateMemoryLimit(.criticalThreshold)
        #expect(!frames.capturesFrames)
        frames.capture(page.view, in: page.host)
        #expect(!page.view.redraw.givesNewTabFrame, "a capture armed although the limit keeps no frame")

        frames.updateMemoryLimit(.default)
        #expect(frames.capturesFrames)
        frames.capture(page.view, in: page.host)
        #expect(page.view.redraw.givesNewTabFrame, "the full limit takes frames again")
    }

    @Test func newTabFramesStopWhenTheSliceExpires() {
        let frames = AgentPaneNewTabFrame()
        for side in [10, 20, 30] { frames.store(Self.frame(side), size: Self.size(side), appearance: nil, generation: 0) }

        let expired = MemoryReleaseSlice(limit: .criticalThreshold) { true }
        #expect(frames.releaseMemory(within: expired) == .more)
        #expect(frames.frameCount == 3)
    }

    // MARK: The package's registrations

    /// The app's registration line registers the three caches under their names; the icons' entry
    /// stays live and the coordinator's limit reaches the icons' actor through the hop.
    @Test func thePackageRegistersItsThreeCachesAndTheLimitReachesTheIconsActor() async throws {
        let home = try Self.home()
        defer { try? FileManager.default.removeItem(atPath: (home as NSString).deletingLastPathComponent) }
        let registry = FakeRegistry()
        registry.limit = .criticalThreshold
        let hops = HopRecorder()
        let frames = AgentPaneNewTabFrame()
        let icons = AgentPaneProjectIcons(reader: AgentPaneProjectIcon(home: home))
        let tails = AgentPaneTailCache.shared
        tails.clear()
        defer {
            tails.updateMemoryLimit(.default)
            tails.clear()
        }

        AgentPaneMemoryConsumers(registry: registry, hop: hops.hop, frames: frames, tails: tails, icons: icons).register()

        #expect(registry.entries.map(\.name) == ["agent-new-tab-frames", "agent-chat-tails", "agent-project-icons"])
        #expect(registry.entries.allSatisfy { $0.isLive })
        #expect(hops.pending == 1, "the icons' limit leaves the main actor through the injected hop")
        #expect(await icons.icon(for: home + "/code/site") != nil)
        #expect(await icons.count == 1, "the limit reached the icons before the hop ran")

        await hops.runAll()
        _ = await icons.releaseMemory(downTo: .criticalThreshold)
        #expect(await icons.icon(for: home + "/code/site") != nil)
        #expect(await icons.count == 0, "the critical limit never reached the icons' actor")
        #expect(registry.entries.last?.isLive == true, "the icons' registration was not kept")
    }

    // MARK: Chat tails

    private static func tail(_ mark: String) -> JSONValue {
        .object(["events": .array([.object(["seq": .number(1), "text": .string(mark)])])])
    }

    @Test func chatTailsReleaseTheLeastRecentlyRememberedAndAReleasedChatIsAskedAgain() {
        let cache = AgentPaneTailCache.shared
        cache.clear()
        defer {
            cache.updateMemoryLimit(.default)
            cache.clear()
        }
        for index in 0..<AgentPaneTailCache.chats { cache.remember(Self.tail("\(index)"), for: "s-\(index)") }
        #expect(cache.memoryUsage?.entries == AgentPaneTailCache.chats)
        #expect((cache.memoryUsage?.footprintBytes ?? 0) > 0)

        #expect(cache.releaseMemory(within: Self.slice(50)) == .done)

        #expect(cache.count == AgentPaneTailCache.chats / 2)
        #expect(cache.tail(for: "s-0") == nil)
        #expect(cache.tail(for: "s-\(AgentPaneTailCache.chats - 1)") != nil)
        // The page hands the released chat's tail over again when it reads it.
        cache.remember(Self.tail("again"), for: "s-0")
        #expect(cache.tail(for: "s-0") == Self.tail("again"))
    }

    @Test func chatTailsAtLimitZeroKeepNone() {
        let cache = AgentPaneTailCache.shared
        cache.clear()
        defer {
            cache.updateMemoryLimit(.default)
            cache.clear()
        }
        cache.remember(Self.tail("a"), for: "s-a")

        cache.updateMemoryLimit(.criticalThreshold)
        #expect(cache.releaseMemory(within: Self.slice(0)) == .done)
        cache.remember(Self.tail("b"), for: "s-b")

        #expect(cache.count == 0)
        #expect(cache.memoryUsage == MemoryUsage.empty)
    }

    // MARK: Project icons

    private static let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 0x0D])

    /// A home folder with `code/site/favicon.png`, resolved as the reader resolves paths.
    private static func home() throws -> String {
        let made = FileManager.default.temporaryDirectory.appendingPathComponent("project-icon-memory-\(UUID().uuidString)/home").path
        try FileManager.default.createDirectory(atPath: made + "/code/site", withIntermediateDirectories: true)
        try png.write(to: URL(fileURLWithPath: made + "/code/site/favicon.png"))
        guard let resolved = realpath(made, nil) else { throw CocoaError(.fileNoSuchFile) }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    @Test func projectIconsAtLimitZeroKeepNoneAndAReleasedIconIsReadAgain() async throws {
        let home = try Self.home()
        defer { try? FileManager.default.removeItem(atPath: (home as NSString).deletingLastPathComponent) }
        let icons = AgentPaneProjectIcons(reader: AgentPaneProjectIcon(home: home))
        let expected = "data:image/png;base64," + Self.png.base64EncodedString()

        #expect(await icons.icon(for: home + "/code/site") == expected)
        #expect(await icons.count == 1)
        #expect(await icons.bytes == expected.utf8.count)

        #expect(await icons.releaseMemory(downTo: .criticalThreshold) == MemoryUsage.empty)
        #expect(await icons.count == 0)
        #expect(await icons.bytes == 0)

        #expect(await icons.updateMemoryLimit(.criticalThreshold) == MemoryUsage.empty)
        // Read again from the file, and not kept at limit 0.
        #expect(await icons.icon(for: home + "/code/site") == expected)
        #expect(await icons.count == 0)

        #expect(await icons.updateMemoryLimit(.default) == MemoryUsage.empty)
        #expect(await icons.icon(for: home + "/code/site") == expected)
        #expect(await icons.count == 1)
    }
}

/// Holds the deliveries of an ``AsyncMemoryConsumerHop`` until the test runs them.
nonisolated final class HopRecorder: Sendable {
    private let deliveries = Mutex<[@Sendable () async -> Void]>([])

    var hop: AsyncMemoryConsumerHop {
        AsyncMemoryConsumerHop { delivery in self.deliveries.withLock { $0.append(delivery) } }
    }

    /// How many deliveries wait to run.
    var pending: Int {
        deliveries.withLock { $0.count }
    }

    /// Runs the waiting deliveries, in the order they were posted.
    func runAll() async {
        let waiting = deliveries.withLock { deliveries in
            let waiting = deliveries
            deliveries = []
            return waiting
        }
        for delivery in waiting { await delivery() }
    }
}
