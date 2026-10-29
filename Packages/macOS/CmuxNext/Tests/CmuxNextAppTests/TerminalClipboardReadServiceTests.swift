import AppKit
@testable import CmuxNextApp
@testable import CmuxNextDaemon
import CmuxNextDesign
import CmuxNextWakeups
import Foundation
import Testing

/// The clipboard-read service follows the local store with one `.sameTurn` FrameObservation: the
/// changes of one turn reach the broker once, on the next main run loop pass, with no display frame and no `Task`
/// per change; a side event in the change's own turn flushes them to the broker first; after `stop()` nothing
/// reaches it.
@MainActor @Suite(.serialized)
struct TerminalClipboardReadServiceTests {
    private static func started() -> (AppServices, TerminalClipboardReadService) {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        _ = services.daemon.store.apply(.connected(DaemonIdentity(generation: "boot"), generationChanged: true))
        let service = TerminalClipboardReadService(services: services)
        service.start()
        return (services, service)
    }

    @Test func theChangesOfOneTurnReachTheBrokerOnceOnTheNextRunLoopPass() async {
        let (services, service) = Self.started()
        defer { service.stop() }
        #expect(service.handOffs == 1, "start hands the current state over in its own turn")
        let store = services.daemon.store
        store.apply(.disconnected(reason: "first"))
        store.apply(.disconnected(reason: "second"))
        #expect(service.handOffs == 1, "a change reached the broker inside its will-set")
        await drainMainTurns()
        #expect(service.handOffs == 2, "\(service.handOffs - 1) hand-offs for two changes in one turn (want 1)")
        await drainMainTurns()
        #expect(service.handOffs == 2, "a hand-off with nothing changed (a re-arm)")
    }

    @Test func aSideEventInTheTurnOfADisconnectReachesTheBrokerAfterTheDisconnect() async {
        let (services, service) = Self.started()
        defer { service.stop() }
        let store = services.daemon.store
        store.apply(.disconnected(reason: "dropped"))
        #expect(service.handOffs == 1)
        // No run loop pass between them: the handler hands the disconnect over before the broker sees the event.
        store.sideEvents.deliver(.terminalClipboardReadCancelled(requestID: "r1"))
        #expect(service.handOffs == 2, "the side event reached the broker before the disconnect")
        await drainMainTurns()
        #expect(service.handOffs == 2, "the run loop apply handed the disconnect over again")
    }

    @Test func nothingReachesTheBrokerAfterStop() async {
        let (services, service) = Self.started()
        service.stop()
        services.daemon.store.apply(.disconnected(reason: "after stop"))
        await drainMainTurns()
        #expect(service.handOffs == 1)
    }

    /// The prompt's scope reads the tab's node, not a walk up its views (recipe R-vis): a tab in an
    /// occluded window (covered, or cmux behind another app) still gets the tab-scoped dialog, as the view walk gave it;
    /// a hidden tab (unselected, parked, miniaturized) gets the active window.
    @Test func aTabInAnOccludedWindowKeepsItsTabScopedPrompt() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: .borderless, backing: .buffered, defer: true)
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        window.contentView = view
        let windowNode = VisibilityNode(root: "window", own: .occluded)
        let tabNode = VisibilityNode("tab:1", parent: windowNode)
        let occluded = TerminalClipboardReadService.scope(tabView: view, tabNode: tabNode, activeWindow: window)
        guard case .tab(let scoped) = occluded else { Issue.record("an occluded window's tab got \(occluded.kind)"); return }
        #expect(scoped === view)

        tabNode.set(.hidden)
        let hidden = TerminalClipboardReadService.scope(tabView: view, tabNode: tabNode, activeWindow: window)
        #expect(hidden.kind == "window", "a hidden tab's prompt goes to the active window")
        #expect(TerminalClipboardReadService.scope(tabView: nil, tabNode: nil, activeWindow: nil).kind == "app")
    }
}
