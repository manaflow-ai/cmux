import AppKit
@testable import CmuxNextTerminal
import CmuxNextWakeups
import Testing

/// The Ghostty config revision replaces the `configDidChange` broadcast (p06-scheduler-044): a
/// terminal host follows it through a `VisibleObservation` on its tab node, so a reload does no work
/// for a hidden terminal and showing it lays out once.
@MainActor @Suite struct GhosttyConfigRevisionTests {
    /// A display link the test never fires: these cases run no frame.
    private final class IdleLink: FrameLink {
        var isPaused = false
        func invalidate() {}
    }

    private let work: MainWorkScheduler

    init() {
        work = MainWorkScheduler.testing { _ in IdleLink() }
    }

    private func makeHost(_ revision: GhosttyConfigRevision, under node: VisibilityNode) -> TerminalHostView {
        let host = TerminalHostView(configRevision: revision)
        host.followConfig(node, on: work)
        return host
    }

    @Test("a reload with 20 hidden terminals does 0 hidden work; each lays out once on show")
    func hiddenHostsDoNoWorkOnReload() {
        let revision = GhosttyConfigRevision()
        let nodes = (0 ..< 20).map { VisibilityNode(root: "tab:\($0)", own: .hidden) }
        let hosts = nodes.map { makeHost(revision, under: $0) }
        #expect(hosts.map { $0.configLayouts } == Array(repeating: 1, count: 20), "the first value applies when the host starts following")
        for _ in 0 ..< 100 { revision.bump() }
        #expect(hosts.map { $0.configTrackingCallbacks } == Array(repeating: 0, count: 20), "a hidden host armed a tracking")
        #expect(hosts.map { $0.configLayouts } == Array(repeating: 1, count: 20), "a hidden host laid out for a reload")
        for node in nodes { node.set(.visible) }
        #expect(hosts.map { $0.configLayouts } == Array(repeating: 2, count: 20), "100 changes while hidden: 1 layout on show")
        #expect(hosts.allSatisfy { $0.needsLayout })
    }

    @Test("hide then show with no change in between lays out nothing")
    func showWithoutChangeLaysOutNothing() {
        let revision = GhosttyConfigRevision()
        let node = VisibilityNode(root: "tab", own: .visible)
        let host = makeHost(revision, under: node)
        node.set(.hidden)
        node.set(.visible)
        #expect(host.configLayouts == 1, "the revision did not move")
    }

    @Test("a visible host tracks the revision; a hidden one drops its tracking")
    func visibleHostTracksAndHiddenDrops() {
        let revision = GhosttyConfigRevision()
        let node = VisibilityNode(root: "tab", own: .visible)
        let host = makeHost(revision, under: node)
        revision.bump()
        #expect(host.configTrackingCallbacks == 1, "a visible host saw the change")
        node.set(.hidden)
        let afterHide = host.configTrackingCallbacks
        for _ in 0 ..< 10 { revision.bump() }
        #expect(host.configTrackingCallbacks == afterHide, "a tracking stayed registered after hide")
    }

    @Test("following again replaces the old observation")
    func followAgainReplaces() {
        let revision = GhosttyConfigRevision()
        let old = VisibilityNode(root: "old", own: .hidden)
        let host = makeHost(revision, under: old)
        let new = VisibilityNode(root: "new", own: .hidden)
        host.followConfig(new, on: work)
        #expect(host.configLayouts == 2)
        revision.bump()
        old.set(.visible)
        #expect(host.configLayouts == 2, "the old node's show reads nothing: its observation was cancelled")
        new.set(.visible)
        #expect(host.configLayouts == 3)
    }
}
