import AppKit
import CmuxHomeCore
@testable import CmuxNextAgentPane
@testable import CmuxNextApp
import CmuxNextDesign
import CmuxNextFeedClient
@testable import CmuxNextHome
import CmuxNextPages
import CmuxNextSettings
import CmuxNextTestSupport
import Darwin
import Foundation
import Observation
import Testing

/// Chief Home's pinned Needs you section (Leo, via his Chief: "a pinned Needs you view in Chief
/// Home, Feed and iPhone listing items waiting on Leo"): the Feed page on `#/needs-you`, sized from
/// the daemon's Needs you view (`feed.view.read {layout: needs_you}`, no second store); it shows
/// only in a Chief's conversation and only while something waits; it sits under the header over the
/// transcript, so showing or hiding it moves no message. It is opt-in (Leo 2026-11-03: "I just
/// wanted to see permission things, period, not a pinned thing by default. Toggle-on, yes"): off by
/// default (`feed.needsYouInChief`), nothing is pinned and the Feed still lists the requests.
@MainActor @Suite(.serialized, .closesItsWindows) struct HomeNeedsYouTests {
    /// The daemon's Needs you view with `ids` waiting; `live` false is a view before the owner answered.
    private static func needsYou(_ ids: [String], live: Bool = true) -> String {
        let entries = ids.map { #"{"id":"\#($0)","item":{"id":"\#($0)","type":"request","kind":"approve","state":"open"}}"# }
        let connection = live ? "connected" : "connecting"
        return #"{"loaded":\#(live),"connection":{"state":"\#(connection)"},"groups":[{"id":"needs_you","entries":[\#(entries.joined(separator: ","))]}]}"#
    }

    /// Lets main-actor tasks run until `condition` holds (bounded).
    private func until(_ condition: () -> Bool) async {
        var tries = 0
        while !condition(), tries < 400 {
            tries += 1
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    @Test func itIsTheHeaderAndARowPerRequestUpToThree() {
        #expect(FeedNeedsYouSection.height(waiting: 0) == 0, "nothing waits: hidden")
        // The page's CSS px: the page and the card pad 4 each, the header 24, a row 40.
        #expect(FeedNeedsYouSection.height(waiting: 1) == CGFloat(8 * 2 + 24 + 40))
        #expect(FeedNeedsYouSection.height(waiting: 3) == 160, "three rows fit at 100%")
        #expect(FeedNeedsYouSection.height(waiting: 7) == FeedNeedsYouSection.height(waiting: 3), "the page counts the rest")
        let section = FeedNeedsYouSection(page: NSView())
        section.waiting = 2
        #expect(section.intrinsicContentSize.height == FeedNeedsYouSection.height(waiting: 2))
    }

    /// Review F1 of #37378: the page follows `ui.scale`, so the section is its CSS height times the
    /// page's zoom; at 125% three rows need 200 points, not 160.
    @Test func threeRowsFitAtEveryScale() {
        #expect(FeedNeedsYouSection.height(waiting: 3, zoom: 1.25) == 200)
        let section = FeedNeedsYouSection(page: NSView())
        section.waiting = 3
        section.zoom = 1.25
        #expect(section.intrinsicContentSize.height == 200)
        #expect(section.fittingSize.height == 200)
    }

    /// A `ui.scale` change resizes the pinned section live: the Feed page's zoom change gives the
    /// section its new zoom and the host measures it again.
    @Test func aScaleChangeResizesTheHost() async throws {
        let saved = DesignSettings.shared.uiScale
        defer { DesignSettings.shared.uiScale = saved }
        DesignSettings.shared.uiScale = 1
        let directory = FileManager.default.temporaryDirectory.appending(path: "needs-you-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("<!doctype html><title>Needs you</title>".utf8).write(to: directory.appending(path: "index.html"))
        let descriptor = PageDescriptor(id: "test.needs-you", resource: "needs-you", namespaces: [])
        let page = try #require(PageWebView(descriptor: descriptor, root: directory, routes: []))
        defer { page.close() }

        let daemon = FakeFeedDaemon()
        daemon.reply("feed.view.read", Self.needsYou(["a", "b", "c"]))
        let host = PinHost(), toggle = PinToggle()
        toggle.on = true
        let watch = FeedNeedsYouSection.watch(feed: daemon.client, isEnabled: { toggle.on }, host: host) {
            FeedNeedsYouSection(page: page, zoom: { [weak page] in page?.pageZoom ?? 1 }) { page.onZoomChange = $0 }
        }
        defer { watch.cancel() }
        await until { host.pinnedSection != nil }
        let section = try #require(host.pinnedSection as? FeedNeedsYouSection)
        #expect(section.fittingSize.height == 160)
        let resizes = host.resizes

        DesignSettings.shared.uiScale = 1.25
        await until { host.resizes > resizes }
        #expect(host.resizes > resizes, "a scale change measures the section again")
        #expect(section.zoom == 1.25)
        #expect(section.fittingSize.height == 200, "three rows fit at 125%")
    }

    @Test func itIsOffByDefaultAndTheSettingTurnsItOn() throws {
        #expect(HomeNeedsYouSetting.fallback == false)
        let unset = CmuxConfigSnapshot.parse(.object([:]), validDensities: [], validMetrics: [])
        #expect(unset.homeNeedsYouInChief == false, "unset cmux.json: no pinned card")
        let on = CmuxConfigSnapshot.parse(try JSONValue.parse(Data(#"{"feed":{"needsYouInChief":true}}"#.utf8)),
                                          validDensities: [], validMetrics: [])
        #expect(on.homeNeedsYouInChief == true)
        let row = try #require(SettingsSchema.descriptor(for: HomeNeedsYouSetting.configPath))
        #expect(row.defaultValue == .bool(false), "Settings shows it off by default")
    }

    @Test func offPinsNothingAndOnPinsTheDaemonsRequestsLive() async {
        let daemon = FakeFeedDaemon()
        daemon.reply("feed.view.read", Self.needsYou(["a"]))
        let host = PinHost(), toggle = PinToggle()
        let watch = FeedNeedsYouSection.watch(feed: daemon.client, isEnabled: { toggle.on }, host: host) { FeedNeedsYouSection(page: NSView()) }
        defer { watch.cancel() }
        await until { host.updates > 0 }
        #expect(host.pinnedSection == nil, "off by default: nothing pinned while a request waits")
        #expect(daemon.ops.isEmpty, "off reads nothing")
        toggle.on = true // the app's setting is observable the same way, so turning it on pins at once
        await until { host.pinnedSection != nil }
        #expect((host.pinnedSection as? FeedNeedsYouSection)?.waiting == 1)
        #expect(daemon.calls.last?.params["layout"]?.stringValue == "needs_you")

        // A second request: the same section grows.
        let section = host.pinnedSection
        daemon.reply("feed.view.read", Self.needsYou(["a", "b"]))
        daemon.client.deliver(.init(changed: ["b"]))
        await until { host.resizes > 0 }
        #expect(host.pinnedSection === section)
        #expect((host.pinnedSection as? FeedNeedsYouSection)?.waiting == 2)

        // Before the owner answers (a reconnect), an empty view is not "nothing waits".
        daemon.reply("feed.view.read", Self.needsYou([], live: false))
        let reads = daemon.calls.count
        daemon.client.deliver(.init(changed: nil))
        await until { daemon.calls.count > reads }
        try? await Task.sleep(for: .milliseconds(50)) // the read's decode and its (absent) change
        #expect(host.pinnedSection === section)

        // Answered: nothing waits, the section goes.
        daemon.reply("feed.view.read", Self.needsYou([]))
        daemon.client.deliver(.init(changed: ["a", "b"]))
        await until { host.pinnedSection == nil }
        #expect(host.pinnedSection == nil)

        // Off again: nothing pinned and no more reads.
        daemon.reply("feed.view.read", Self.needsYou(["c"]))
        let updates = host.updates
        toggle.on = false
        await until { host.updates > updates } // the watch saw the setting go off (it unpins, so it updates)
        let after = daemon.calls.count
        daemon.client.deliver(.init(changed: ["c"]))
        try? await Task.sleep(for: .milliseconds(50))
        #expect(daemon.calls.count == after, "off reads nothing")
        #expect(host.pinnedSection == nil)
    }

    /// `permission-feed-peer`: the scene's bridge (the same arguments as
    /// `CaptureSceneRegistry.renderPermissionFeedPeer`) against the scene's acpmux fixture posts the
    /// peer's prompt to the feed, and Needs you draws it. The feed ops go to a fake Needs you view
    /// instead of the app's daemon. Review of #41480: the scene failed before it drew Needs you.
    @Test func thePermissionFeedPeerSceneDrawsThePrompt() async throws {
        let scene = try await PermissionFeedScene.start()
        defer { scene.stop() }
        try await scene.posted()
        #expect(scene.waiting == 1, "Needs you drew the prompt")
        // Review F2 of #41480: assert only once the bridge handled the notice, so a second post fails.
        let handled = scene.pendingNoticesHandled
        scene.capture.notifyPending()
        try await scene.until("the bridge never handled the live notice") { scene.pendingNoticesHandled > handled }
        #expect(scene.bridgePosts == 1, "the live notice posts no second item: \(scene.feed.ops)")
        #expect(scene.feed.ops.filter { $0 == "feed.post" }.count <= 1, "the live notice posts no second item: \(scene.feed.ops)")
    }

    /// `permission-feed-peer-resolved`: answered on the peer, the bridge withdraws the item and
    /// Needs you hides it.
    @Test func thePermissionFeedPeerResolvedSceneWithdrawsThePrompt() async throws {
        let scene = try await PermissionFeedScene.start()
        defer { scene.stop() }
        try await scene.posted()
        scene.capture.notifyPending()
        scene.capture.resolve()
        try await scene.withdrawn()
        #expect(scene.waiting == 0, "Needs you hid the answered prompt")
    }

    /// The scenes' acpmux reads a peer session by the ids acpmux itself routes on its unix socket:
    /// the qualified id, and the raw id that names one live session (`hub/key_route.rs`
    /// `key_candidates`: `id.starts_with(key)` over the peer rows' `mux_session_id`), as the bridge's
    /// notices carry it. Any other id is an error.
    @Test func theScenesAcpmuxReadsAPeerSessionByEitherId() async throws {
        let capture = try HomeNeedsYouCapture(send: { op, _ in op })
        defer { capture.stop() }
        let socket = capture.socket
        let answers = await Task.detached { FixtureClient.infoAnswers(socket: socket, ids: [
            HomeNeedsYouCapture.qualifiedSession, HomeNeedsYouCapture.rawSession, "acp_other",
        ]) }.value
        #expect(answers.count == 3, "answers: \(answers)")
        #expect(answers.first == "pending 1", "the qualified id: \(answers)")
        #expect(answers.dropFirst().first == "pending 1", "the raw id acpmux routes to the one peer row: \(answers)")
        #expect(answers.last == "error", "an id no session has: \(answers)")
    }

    @Test func thePinnedSectionSitsUnderTheHeaderAndMovesNoMessage() async throws {
        let source = EmptyChiefSource()
        let id = ConversationID("conv_chief")
        let inbox = try await source.inbox()
        let store = HomeStore(source: source)
        store.start()
        let view = HomeNativeTranscriptView(store: store, conversation: id, me: inbox.me.id)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 800), styleMask: [.titled],
                              backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        defer { view.stop(); store.stop(); window.close() }
        view.frame = NSRect(x: 0, y: 0, width: 600, height: 800)
        window.contentView = view
        await view.binding.opened()
        view.layoutSubtreeIfNeeded()
        let transcriptFrame = view.transcript.frame
        #expect(view.pinnedSection == nil)

        let section = FeedNeedsYouSection(page: NSView())
        section.waiting = 1
        view.setPinnedSection(section)
        view.layoutSubtreeIfNeeded()
        #expect(view.pinnedSection === section)
        #expect(section.superview === view)
        #expect(section.frame.minY >= view.headerHeight, "under the header: \(section.frame) header \(view.headerHeight)")
        #expect(section.frame.height > 0)
        #expect(section.frame.maxY < view.transcript.fieldTop, "above the message box")
        #expect(view.transcript.frame == transcriptFrame, "the transcript keeps its frame: nothing shifts")
        // The oldest message can still scroll out from under the card (Codex review, #33817).
        #expect(view.transcript.rowsTopClearance >= section.frame.maxY - view.headerHeight)

        view.setPinnedSection(nil)
        view.layoutSubtreeIfNeeded()
        #expect(view.pinnedSection == nil)
        #expect(section.superview == nil)
        #expect(view.transcript.rowsTopClearance == 0)
        #expect(view.transcript.frame == transcriptFrame)
    }

    @Test func theSetupCardFitsAShortPaneAndIsNeverHidden() async throws {
        let source = EmptyChiefSource()
        let id = ConversationID("conv_chief")
        let inbox = try await source.inbox()
        let store = HomeStore(source: source)
        store.start()
        let view = HomeNativeTranscriptView(store: store, conversation: id, me: inbox.me.id)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 420), styleMask: [.titled],
                              backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        defer { view.stop(); store.stop(); window.close() }
        view.frame = NSRect(x: 0, y: 0, width: 600, height: 420)
        window.contentView = view
        await view.binding.opened()
        let card = NSView()

        view.setSetupCard(card, height: 0)
        view.layoutSubtreeIfNeeded()
        #expect(!card.isHidden && card.frame.height == 1, "unsized, the page stays in the window to measure: \(card.frame)")

        // Taller than the pane: the slot stops above the message box and the page scrolls inside it.
        view.setSetupCard(card, height: 2000)
        view.layoutSubtreeIfNeeded()
        #expect(card.frame.height > 1 && card.frame.height < 2000, "\(card.frame)")
        #expect(card.frame.maxY < view.transcript.fieldTop, "above the message box")

        // Needs you rows taller than the pane: the pinned section gives way, and the card keeps a usable height.
        let pinned = TallSection()
        view.setPinnedSection(pinned)
        view.layoutSubtreeIfNeeded()
        #expect(card.frame.height >= 120, "the card keeps its title and a row: \(card.frame)")
        #expect(pinned.frame.maxY < card.frame.minY && card.frame.maxY < view.transcript.fieldTop, "\(pinned.frame) \(card.frame)")
        view.setPinnedSection(nil)
    }
}

/// The `permission-feed-peer` scenes' fixture and bridge (CaptureSceneRegistry+Home.swift), with
/// the feed ops on a fake feed daemon whose Needs you view the pinned section reads.
@MainActor private final class PermissionFeedScene {
    let capture: HomeNeedsYouCapture
    let feed: FeedOps
    private let daemon: FakeFeedDaemon
    private let host: PinHost
    private let watch: Task<Void, Never>
    private var bridge: AcpmuxPermissionFeedBridge?

    private init(capture: HomeNeedsYouCapture, feed: FeedOps, daemon: FakeFeedDaemon, host: PinHost,
                 watch: Task<Void, Never>, bridge: AcpmuxPermissionFeedBridge) {
        (self.capture, self.feed, self.daemon, self.host, self.watch, self.bridge) = (capture, feed, daemon, host, watch, bridge)
    }

    static func start() async throws -> PermissionFeedScene {
        let feed = FeedOps()
        let capture = try HomeNeedsYouCapture(send: { op, _ in
            feed.add(op)
            return "\(op): ok"
        })
        let daemon = FakeFeedDaemon()
        daemon.reply("feed.view.read", Self.needsYou([]))
        let host = PinHost(), toggle = PinToggle()
        toggle.on = true
        let watch = FeedNeedsYouSection.watch(feed: daemon.client, isEnabled: { toggle.on }, host: host) { FeedNeedsYouSection(page: NSView()) }
        let bridge = AcpmuxPermissionFeedBridge(
            environment: try environment(capture.socket),
            owner: { _, body in capture.owner(body) }, isSignedIn: { true }, ownInstall: { "inst_capture_mac" },
            presenceKeys: { throw CancellationError() })
        bridge.start()
        return PermissionFeedScene(capture: capture, feed: feed, daemon: daemon, host: host, watch: watch, bridge: bridge)
    }

    /// The prompts Needs you draws.
    var waiting: Int { (host.pinnedSection as? FeedNeedsYouSection)?.waiting ?? 0 }
    /// The `_acpmux/permission_pending` notices the bridge finished handling.
    var pendingNoticesHandled: Int { bridge?.pendingNoticesHandled ?? 0 }
    /// The feed items the bridge holds as posted (set before it counts a notice handled).
    var bridgePosts: Int { bridge?.posted.count ?? 0 }

    /// Waits (5 s at most) for the bridge's `feed.post`, then shows the item in the Needs you view.
    func posted() async throws {
        try await until("the bridge posted no feed item; acpmux info reads: \(capture.infoReads)") { self.feed.ops.contains("feed.post") }
        daemon.reply("feed.view.read", Self.needsYou([HomeNeedsYouCapture.feedKey]))
        daemon.client.deliver(.init(changed: [HomeNeedsYouCapture.feedKey]))
        try await until("Needs you did not draw the posted item") { self.waiting == 1 }
    }

    /// Waits (5 s at most) for the bridge's `feed.withdraw`, then hides the item in the Needs you view.
    func withdrawn() async throws {
        try await until("the bridge kept the answered prompt; acpmux info reads: \(capture.infoReads), feed: \(feed.ops)") {
            self.feed.ops.contains("feed.withdraw")
        }
        daemon.reply("feed.view.read", Self.needsYou([]))
        daemon.client.deliver(.init(changed: [HomeNeedsYouCapture.feedKey]))
        try await until("Needs you kept the withdrawn item") { self.waiting == 0 }
    }

    func stop() {
        bridge = nil
        watch.cancel()
        capture.stop()
    }

    struct NotReached: Error, CustomStringConvertible { let description: String }

    func until(_ why: @autoclosure () -> String, _ condition: () -> Bool) async throws {
        var tries = 0
        while !condition(), tries < 1_000 {
            tries += 1
            try? await Task.sleep(for: .milliseconds(5))
        }
        if !condition() { throw NotReached(description: why()) }
    }

    private static func needsYou(_ ids: [String]) -> String {
        let entries = ids.map { #"{"id":"\#($0)","item":{"id":"\#($0)","type":"request","kind":"approve","state":"open"}}"# }
        return #"{"loaded":true,"connection":{"state":"connected"},"groups":[{"id":"needs_you","entries":[\#(entries.joined(separator: ","))]}]}"#
    }

    /// The test process is the server peer the bridge checks for: the fixture runs in it.
    private static func environment(_ socket: String) throws -> AcpmuxEnvironment {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        try #require(proc_pidpath(getpid(), &buffer, UInt32(buffer.count)) > 0)
        let executable = URL(fileURLWithPath: String(cString: buffer)).resolvingSymlinksInPath()
        let home = URL(fileURLWithPath: (socket as NSString).deletingLastPathComponent, isDirectory: true)
        return AcpmuxEnvironment(executable: executable, home: home, socketPath: socket, daemonArguments: [], childEnvironment: [:])
    }
}

/// The feed ops the scene's fixture sent, from any thread.
private nonisolated final class FeedOps: @unchecked Sendable { // crash-allow: `all` is read and written under `lock`
    private let lock = NSLock()
    private var all: [String] = []
    var ops: [String] { lock.withLock { all } }
    func add(_ op: String) { lock.withLock { all.append(op) } }
}

/// A blocking JSON-RPC client of the scenes' acpmux socket, off the main actor.
private nonisolated enum FixtureClient {
    /// `_acpmux/info` for each id in turn: "pending N", "error", or "no answer" (5 s each).
    static func infoAnswers(socket: String, ids: [String]) -> [String] {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return ["no socket"] }
        defer { close(fd) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let path = Array(socket.utf8CString)
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in path.withUnsafeBytes { buffer.copyMemory(from: $0) } }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard connected == 0 else { return ["no connection"] }
        var limit = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &limit, socklen_t(MemoryLayout<timeval>.size))
        var buffer = Data()
        return ids.enumerated().map { index, id in
            let request: [String: Any] = ["jsonrpc": "2.0", "id": index + 1, "method": "_acpmux/info", "params": ["sessionId": id]]
            guard var frame = try? JSONSerialization.data(withJSONObject: request) else { return "no request" }
            frame.append(0x0A)
            _ = frame.withUnsafeBytes { Darwin.send(fd, $0.baseAddress, frame.count, 0) }
            while true {
                if let newline = buffer.firstIndex(of: 0x0A) {
                    let line = buffer[buffer.startIndex..<newline]
                    buffer.removeSubrange(buffer.startIndex...newline)
                    guard let reply = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
                          reply["id"] as? Int == index + 1 else { continue }
                    if reply["error"] != nil { return "error" }
                    return "pending \(((reply["result"] as? [String: Any])?["pending"] as? [Any])?.count ?? 0)"
                }
                var chunk = [UInt8](repeating: 0, count: 4096)
                let count = recv(fd, &chunk, chunk.count, 0)
                guard count > 0 else { return "no answer" }
                buffer.append(contentsOf: chunk[0..<count])
            }
        }
    }
}

/// Needs you rows taller than any pane.
private final class TallSection: NSView {
    override var fittingSize: NSSize { NSSize(width: 400, height: 2000) }
}

/// A stand-in for `feed.needsYouInChief` (the app reads it from the observable settings snapshot).
@MainActor @Observable private final class PinToggle { var on = false }

/// A stand-in for Chief Home's transcript: records what the pin puts under its header.
@MainActor private final class PinHost: FeedPinnedSectionHost {
    private(set) var pinnedSection: NSView?
    private(set) var updates = 0
    func setPinnedSection(_ view: NSView?) { pinnedSection = view; updates += 1 }
    private(set) var resizes = 0
    func pinnedSectionDidResize() { resizes += 1 }
}
