import AppKit
@testable import CmuxNextTerminal
import CmuxNextWakeups
import GhosttyNextKit
import Testing

/// The Ghostty config revision replaces the `configDidChange` broadcast: a
/// terminal host follows it through a `VisibleObservation` on its tab node, so a reload does no work
/// for a hidden terminal, a visible one lays out once per frame however many changes came, and
/// showing a hidden one lays out once.
@MainActor @Suite(.timeLimit(.minutes(1))) struct GhosttyConfigRevisionTests {
    @Test("a reload with 20 hidden terminals does 0 hidden work; each lays out once on show")
    func hiddenHostsDoNoWorkOnReload() {
        let frames = Frames()
        defer { frames.stop() }
        let revision = GhosttyConfigRevision()
        let nodes = (0 ..< 20).map { VisibilityNode(root: "tab:\($0)", own: .hidden) }
        let hosts = nodes.map { frames.host(revision, under: $0) }
        #expect(hosts.map { $0.configLayouts } == Array(repeating: 1, count: 20), "the first value applies when the host starts following")
        for _ in 0 ..< 100 { revision.bump() }
        frames.fire()
        #expect(hosts.map { $0.configTrackingCallbacks } == Array(repeating: 0, count: 20), "a hidden host armed a tracking")
        #expect(hosts.map { $0.configLayouts } == Array(repeating: 1, count: 20), "a hidden host laid out for a reload")
        for node in nodes { node.set(.visible) }
        #expect(hosts.map { $0.configLayouts } == Array(repeating: 2, count: 20), "100 changes while hidden: 1 layout on show")
        #expect(hosts.allSatisfy { $0.needsLayout })
    }

    @Test("a visible host lays out again on the frame after a change, once for a burst")
    func visibleHostLaysOutOncePerBurst() {
        let frames = Frames()
        defer { frames.stop() }
        let revision = GhosttyConfigRevision()
        let node = VisibilityNode(root: "tab", own: .visible)
        let host = frames.host(revision, under: node)
        #expect(host.configLayouts == 1)
        for _ in 0 ..< 5 { revision.bump() }
        #expect(host.configLayouts == 1, "a change lays out nothing in its own turn")
        frames.fire()
        #expect(host.configLayouts == 2, "5 changes in one turn: 1 layout on the next frame")
        #expect(host.needsLayout)
        revision.bump()
        frames.fire()
        #expect(host.configLayouts == 3, "the host follows the next change too")
        frames.fire()
        #expect(host.configLayouts == 3, "a frame with no change lays out nothing")
    }

    @Test("hide then show with no change in between lays out nothing")
    func showWithoutChangeLaysOutNothing() {
        let frames = Frames()
        defer { frames.stop() }
        let revision = GhosttyConfigRevision()
        let node = VisibilityNode(root: "tab", own: .visible)
        let host = frames.host(revision, under: node)
        node.set(.hidden)
        node.set(.visible)
        #expect(host.configLayouts == 1, "the revision did not move")
    }

    @Test("a hidden host drops its tracking and lays out for no change made while hidden")
    func hiddenHostDropsTracking() {
        let frames = Frames()
        defer { frames.stop() }
        let revision = GhosttyConfigRevision()
        let node = VisibilityNode(root: "tab", own: .visible)
        let host = frames.host(revision, under: node)
        node.set(.hidden)
        let afterHide = host.configTrackingCallbacks
        for _ in 0 ..< 10 { revision.bump() }
        frames.fire()
        #expect(host.configTrackingCallbacks == afterHide, "a tracking stayed registered after hide")
        #expect(host.configLayouts == 1, "a hidden host laid out")
    }

    @Test("following again replaces the old observation")
    func followAgainReplaces() {
        let frames = Frames()
        defer { frames.stop() }
        let revision = GhosttyConfigRevision()
        let old = VisibilityNode(root: "old", own: .hidden)
        let host = frames.host(revision, under: old)
        let new = VisibilityNode(root: "new", own: .hidden)
        host.followConfig(new, on: frames.work)
        #expect(host.configLayouts == 2)
        revision.bump()
        old.set(.visible)
        #expect(host.configLayouts == 2, "the old node's show reads nothing: its observation was cancelled")
        new.set(.visible)
        #expect(host.configLayouts == 3)
    }
}

/// The runtime's side: one revision bump per config change, the services' handlers after it in the
/// order added, and none for a soft reload, which changes no config. Drives the process's one
/// runtime with its own applied config, so it changes nothing the other suites read.
@MainActor @Suite(.serialized) struct GhosttyConfigChangeHandlerTests {
    @Test("a config change bumps the revision once, then runs the handlers in the order added")
    func aChangeBumpsOnceThenRunsHandlersInOrder() throws {
        _ = NSApplication.shared
        let runtime = GhosttyRuntime.startedForTests()
        let applied = try #require(runtime.config, "libghostty did not initialize")
        let calls = HandlerCalls()
        let before = runtime.configRevision.value
        runtime.addConfigChangeHandler { [weak calls, runtime] in calls?.record("first", revision: runtime.configRevision.value) }
        runtime.addConfigChangeHandler { [weak calls, runtime] in calls?.record("second", revision: runtime.configRevision.value) }

        runtime.adoptAppliedConfig(applied)

        #expect(runtime.configRevision.value == before + 1, "one change, one bump")
        #expect(calls.names == ["first", "second"], "handlers run in the order they were added")
        #expect(calls.revisions == [before + 1, before + 1], "a handler ran before the revision counted its change")
    }

    @Test("a soft reload runs the surfaces' theme hook and no config change handler")
    func aSoftReloadRunsNoConfigChangeHandler() throws {
        _ = NSApplication.shared
        let runtime = GhosttyRuntime.startedForTests()
        try #require(runtime.app != nil && runtime.config != nil, "libghostty did not initialize")
        let calls = HandlerCalls()
        runtime.addConfigChangeHandler { [weak calls, runtime] in calls?.record("service", revision: runtime.configRevision.value) }
        let hooks = HandlerCalls()
        let previous = runtime.onConfigChange
        runtime.onConfigChange = { [weak hooks] in
            previous?()
            hooks?.record("hook", revision: 0)
        }
        defer { runtime.onConfigChange = previous }
        let before = runtime.configRevision.value

        #expect(GhosttyActionDispatcher.dispatch(.reloadConfig(soft: true), bridge: nil, runtime: runtime))

        #expect(!hooks.names.isEmpty, "the soft reload skipped the surfaces' theme hook")
        // Ghostty may answer the update with an app-level CONFIG_CHANGE, which is a config change;
        // the soft reload's own hook call is not.
        #expect(UInt64(calls.names.count) == runtime.configRevision.value - before,
                "a handler ran for a soft reload that changed no config")
    }
}

/// A recorder for a test's config change handlers, held weakly by the runtime's handler list.
@MainActor
private final class HandlerCalls {
    private(set) var names: [String] = []
    private(set) var revisions: [UInt64] = []

    func record(_ name: String, revision: UInt64) {
        names.append(name)
        revisions.append(revision)
    }
}

/// A scheduler on hand-fired frames: a link-keeping client holds the frames on, as the app's
/// display link does while work waits, and ``fire()`` runs one 17 ms later than the last.
@MainActor
private final class Frames {
    let work: MainWorkScheduler
    private let keeper: FrameClient
    private let clock: FrameClock
    private var timestamp: Double = 0

    init() {
        let clock = FrameClock()
        self.clock = clock
        work = MainWorkScheduler.testing(budget: MainFrameBudget(uptimeNanos: { clock.now })) { _ in StillLink() }
        keeper = FrameClient(owner: "test.keeper", isAnimation: false, on: work.frames) { _ in true }
        keeper.activate()
    }

    /// A host following `revision` under `node`.
    func host(_ revision: GhosttyConfigRevision, under node: VisibilityNode) -> TerminalHostView {
        let host = TerminalHostView(mainWork: work, configRevision: revision)
        host.followConfig(node, on: work)
        return host
    }

    func fire() {
        clock.now += 17_000_000
        timestamp += 1
        work.frameDidFire(timestamp: timestamp, refreshInterval: 1.0 / 60)
    }

    func stop() {
        keeper.deactivate()
    }
}

/// The budget's clock (`CLOCK_UPTIME_RAW` nanoseconds), moved by ``Frames/fire()``.
@MainActor
private final class FrameClock {
    var now: UInt64 = 1_000_000_000
}

/// A display link fired by hand (``Frames/fire()``).
private final class StillLink: FrameLink {
    var isPaused = false
    func invalidate() {}
}
