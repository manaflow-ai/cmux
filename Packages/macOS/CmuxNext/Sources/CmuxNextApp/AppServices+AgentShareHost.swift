import AppKit
import CmuxNextActions
import CmuxNextDaemon
import CmuxNextDaemonService
import CmuxNextDesign
import CmuxNextFeed
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
    func shareOwnerToken(api: URL?) async -> String? { await cloud.shareOwnerToken(api: api) }
    func shareCopy(_ text: String) { AppActionContext(services: self).copy(text) }
    func shareNotice(_ message: String) { BrowserFileImport.toast(self, id: "agent-share", message) }
    func shareAskOwner(_ ask: AgentShareConsentAsk) async -> Bool { await AgentShareConsentSheet.ask(ask, feed: feed) }
    func shareShowInvites(_ model: AgentShareInviteSheetModel) { AgentShareInviteSheetPresenter.present(model, services: self) }
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

    /// The Feed request while the sheet waits: its "Show on Mac" brings the app forward, never allows.
    static func feedRequest(_ ask: AgentShareConsentAsk) -> FeedPendingConfirm.Request {
        .init(title: ask.title, statement: ask.lines.joined(separator: " "), confirmLabel: ask.showOnMacTitle, cancelLabel: ask.declineTitle)
    }

    static func spec(_ ask: AgentShareConsentAsk) -> CmuxDialogSpec {
        CmuxDialogSpec(title: ask.title, lines: ask.lines,
                       buttons: [.cancel(ask.declineTitle), CmuxDialogButton(id: "allow", title: ask.allowTitle)],
                       identifier: identifier)
    }

    /// `feed`: while the sheet waits it is also an open Feed request (``FeedPendingConfirm``), which only
    /// declines the sheet or brings the app forward.
    static func ask(_ ask: AgentShareConsentAsk, center: CmuxDialogCenter = .shared, within limit: Duration = answerWithin,
                    feed: FeedService? = nil) async -> Bool {
        let timeout = DemandTimer(owner: "AgentShareConsentSheet.ask")
        let request = feed.flatMap { feed in feed.isSignedIn ? FeedPendingConfirm(owner: { try await feed.call($0, $1) }) : nil }
        return await withCheckedContinuation { continuation in
            // The center calls this once: the owner's press, or the dismissal below.
            let id = center.present(spec(ask), in: .app) { answer in
                timeout.cancel()
                // task-owner: AgentShareConsentSheet.ask: one feed.cancel when the sheet ends.
                if let request { Task { await request.close() } }
                continuation.resume(returning: answer.button == "allow")
            }
            // Cancelled by the answer; else ends the dialog at `limit` as a decline.
            timeout.schedule(after: limit) { @MainActor in center.dismiss(id) }
            guard let feed, let request else { return }
            // task-owner: AgentShareConsentSheet.ask: posts the Needs you request, then waits for a Feed
            // answer at most until the sheet's own `limit`; ends with the sheet (close) or the deadline.
            Task { @MainActor in
                let deadline = ContinuousClock.now + limit
                guard let item = await request.open(feedRequest(ask), key: "share-consent:\(UUID().uuidString)",
                                                    expiresInMs: Int(limit.components.seconds) * 1000) else { return }
                await feed.waitClosed(item, until: deadline)
                switch feed.model.item(item).flatMap(FeedPendingConfirm.confirmed) {
                case false?: center.dismiss(id)
                case true?: NSApp.activate()
                case nil: break
                }
            }
        }
    }
}
