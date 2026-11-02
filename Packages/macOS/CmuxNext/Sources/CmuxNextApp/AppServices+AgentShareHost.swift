import AppKit
import CmuxNextActions
import CmuxNextDaemon
import CmuxNextDaemonService
import CmuxNextDesign
import CmuxNextWakeups

// Share with Guest (design chat-multiplayer.md 6): one-line forwards to the App's owners.
extension AppServices: AgentShareHost {
    func shareTab(surface: SurfaceID) -> TabModel? { locateTab(surface: surface) }
    func shareTab(id: String) -> TabModel? { locateTab(id)?.0 }
    func shareTabID(showing session: String) -> String? { agentTabs.tab(showing: session) }
    var shareFocusedTabID: String? { windows.active?.focusedPane?.stripModel.selectedID?.rawValue }
    func shareConnection(holding tab: TabModel) -> DaemonConnection? { locateTab(tab.id).map(\.1).map(daemon(for:))?.connection }
    func shareIsOnThisMac(_ tab: TabModel) -> Bool { machines.local.store.tab(idOrResource: tab.id) === tab }
    var shareLocalConnection: DaemonConnection? { machines.local.connection }
    func shareOwnerToken() async -> String? { await cloud.shareOwnerToken() }
    func shareCopy(_ text: String) { AppActionContext(services: self).copy(text) }
    func shareNotice(_ message: String) { BrowserFileImport.toast(self, id: "agent-share", message) }
    func shareAskOwner(_ ask: AgentShareConsentAsk) async -> Bool { await AgentShareConsentSheet.ask(ask) }
}

/// The owner's consent sheet for a guest link a run they did not start asks for (#30263): a cmux
/// dialog, drawn natively above every page so no script can answer it. Unanswered, it closes as a
/// decline before the caller's person deadline, so the waiting CLI or agent always gets an answer.
@MainActor
enum AgentShareConsentSheet {
    /// The sheet closes early enough that an Allow at its last second still has the daemon's create
    /// (``AgentShareActions/createDeadline``) and a margin inside the caller's person deadline.
    static let answerWithin: Duration = ActionDescriptor.personDeadline - AgentShareActions.createDeadline - .seconds(10)

    /// Only the person answers it (`DebugDialog.userOnly`): the debug socket's press would let the
    /// asking script approve its own link.
    static let identifier = "cmux.dialog.agentShareConsent"

    static func spec(_ ask: AgentShareConsentAsk) -> CmuxDialogSpec {
        CmuxDialogSpec(title: ask.title, lines: ask.lines,
                       buttons: [.cancel(ask.declineTitle), CmuxDialogButton(id: "allow", title: ask.allowTitle)],
                       identifier: identifier)
    }

    static func ask(_ ask: AgentShareConsentAsk, center: CmuxDialogCenter = .shared, within limit: Duration = answerWithin) async -> Bool {
        let timeout = DemandTimer(owner: "AgentShareConsentSheet.ask")
        return await withCheckedContinuation { continuation in
            // The center calls this once: the owner's press, or the dismissal below.
            let id = center.present(spec(ask), in: .app) { answer in
                timeout.cancel()
                continuation.resume(returning: answer.button == "allow")
            }
            // Cancelled by the answer; else ends the dialog at `limit` as a decline.
            timeout.schedule(after: limit) { @MainActor in center.dismiss(id) }
        }
    }
}
