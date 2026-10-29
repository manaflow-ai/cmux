import AppKit
import CmuxNextDesign

/// The "Page unresponsive" card of one cmux page in Chromium. Chrome shows its hung
/// renderer dialog for the tab whose renderer hangs and takes it down when the renderer answers
/// (`Browser::RendererUnresponsive` / `RendererResponsive`, chrome/browser/ui/browser.cc;
/// chrome/browser/ui/views/hung_renderer_view.cc); here that dialog is a tab-scoped ``CmuxDialogSpec``
/// over the page, shown while the renderer hangs and the page shows. A page that hangs while hidden
/// shows the card when it shows; a page that answers again, hides or ends takes it down without
/// answering. Wait (Escape, as closing Chrome's dialog waits) restarts Chromium's hang timer; Exit page
/// ends the renderer, and the page's crash recovery takes over (``PageCrashRecovery``).
@MainActor
final class PageHangNotice {
    /// The dialog's accessibility identifier (automation, page-hang-live.py).
    static let identifier = "page.unresponsive"
    /// The Wait button's id.
    static let waitButton = "wait"
    /// The Exit page button's id.
    static let exitButton = "exit"

    private let center: CmuxDialogCenter
    /// The tab the card blocks; weak, as the dialog center holds its scope.
    private weak var anchor: NSView?
    /// Answers the engine's hang: true ends the renderer, false waits.
    private let answer: @MainActor (_ terminate: Bool) -> Void
    /// The renderer hangs and nothing answered it yet.
    private(set) var isUnresponsive = false
    /// The page shows (``PageWebView/setEngineVisible(_:)``).
    private(set) var isVisible: Bool
    /// The card on screen or queued in its tab; nil while none.
    private(set) var dialogID: Int?
    /// Which presentation an answer belongs to: a card taken down never answers.
    private var presentation = 0

    /// - Parameters:
    ///   - center: The dialog center the card shows in (the host's, ``PageChromiumHosting/dialogs``).
    ///   - anchor: The page view the card blocks.
    ///   - visible: Whether the page shows now.
    ///   - answer: Answers the engine's hang (``PageChromiumPage/answerUnresponsive(terminate:)``).
    init(center: CmuxDialogCenter, anchor: NSView, visible: Bool, answer: @escaping @MainActor (_ terminate: Bool) -> Void) {
        self.center = center
        self.anchor = anchor
        isVisible = visible
        self.answer = answer
    }

    /// The renderer stopped answering (true) or answers again (false).
    func unresponsiveChanged(_ unresponsive: Bool) {
        isUnresponsive = unresponsive
        sync()
    }

    /// The page shows (true) or hides (false).
    func visibilityChanged(_ visible: Bool) {
        isVisible = visible
        sync()
    }

    /// The Chromium page ended (closed, fell back, crashed): the card goes and nothing answers.
    func end() {
        isUnresponsive = false
        sync()
    }

    /// The card the hang shows.
    static var spec: CmuxDialogSpec {
        CmuxDialogSpec(title: title, lines: [message],
                       buttons: [CmuxDialogButton(id: exitButton, title: exit, role: .destructive),
                                 CmuxDialogButton(id: waitButton, title: wait, role: .cancel)],
                       identifier: identifier)
    }

    private func sync() {
        let wanted = isUnresponsive && isVisible
        if wanted, dialogID == nil, let anchor {
            presentation &+= 1
            let token = presentation
            let id = center.present(Self.spec, in: .tab(anchor)) { [weak self] reply in self?.answered(reply, token: token) }
            // A scope already gone ends the dialog inside `present`; that answer cleared the token.
            if presentation == token { dialogID = id }
        } else if !wanted, let id = dialogID {
            dialogID = nil
            presentation &+= 1
            center.dismiss(id)
        }
    }

    private func answered(_ reply: CmuxDialogAnswer, token: Int) {
        guard token == presentation else { return }
        presentation &+= 1
        dialogID = nil
        // The tab or window closed under the card: the page goes with it, so nothing answers.
        guard !reply.isDismissal else { return }
        // Answered: Chromium reports the hang again if the renderer still hangs after Wait.
        isUnresponsive = false
        answer(reply.button == Self.exitButton)
    }

    private static var title: String {
        String(localized: "pages.unresponsive.title", defaultValue: "Page unresponsive", bundle: .module)
    }

    private static var message: String {
        String(localized: "pages.unresponsive.message", defaultValue: "You can wait for it to respond or exit the page.", bundle: .module)
    }

    private static var wait: String {
        String(localized: "pages.unresponsive.wait", defaultValue: "Wait", bundle: .module)
    }

    private static var exit: String {
        String(localized: "pages.unresponsive.exit", defaultValue: "Exit page", bundle: .module)
    }
}
