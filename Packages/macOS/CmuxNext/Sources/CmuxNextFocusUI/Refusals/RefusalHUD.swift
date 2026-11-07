package import AppKit
package import CmuxNextDesign

/// Why a keyboard or menu action refused ("Not enough room to split this
/// column"), instead of a bare beep: a toast in the active window through
/// the one toast component (`CmuxToastCenter`), so it looks, stacks and
/// holds under the pointer like every other toast. A newer refusal replaces
/// the one showing. A refusal that asks the person to sign in carries a Sign In
/// action that starts the sign-in (``signInOffer``; msg 3790: "everywhere we say
/// sign in, we need to have a button for signing in").
@MainActor
package final class RefusalHUD {
    package static let toastID = "refusal"
    private let toasts: CmuxToastCenter
    private var handle: CmuxToastHandle?
    /// How long a message stays.
    package var lifetime: Duration = .seconds(4)
    /// The sign-in that gets past a refusal's reason, or nil when the reason does not ask to sign
    /// in. The App answers a "sign in to cmux" reason with its Sign In action while signed out.
    package var signInOffer: @MainActor (_ reason: String) -> (@MainActor () -> Void)? = { _ in nil }

    package init(toasts: CmuxToastCenter = .shared) {
        self.toasts = toasts
    }

    /// The message currently shown (`debug.window` snapshots).
    package var message: String? { handle.flatMap { $0.isDismissed ? nil : $0.toast.message } }
    /// Messages asked for so far: a caller that may refuse after another
    /// layer already did compares it, so one failure shows one reason.
    package private(set) var shownCount = 0
    #if DEBUG || CMUX_BENCH_HOOKS
    /// Every message asked for, newest last (`debug.toast` `refusals`): a
    /// burst check sees a message the hide deadline already took down.
    package private(set) var history: [String] = []
    #endif

    package func show(_ text: String, in window: NSWindow?) {
        shownCount += 1
        #if DEBUG || CMUX_BENCH_HOOKS
        history = Array((history + [text]).suffix(100))
        #endif
        guard let window else { return }
        let (toast, signIn) = toast(for: text)
        let shown = toasts.show(toast, in: window)
        if let signIn { shown.onAction = { signIn() } }
        handle = shown
    }

    /// The toast for refusal `text`, and the sign-in its Sign In action runs (nil: no action).
    package func toast(for text: String) -> (CmuxToast, (@MainActor () -> Void)?) {
        let signIn = signInOffer(text)
        let action = signIn.map { _ in CmuxToast.Action(title: SignInButton.defaultTitle) }
        // A notice the person can act on stays as long as any other toast with an action.
        let duration: Duration = signIn == nil ? lifetime : .seconds(8)
        return (CmuxToast(id: Self.toastID, message: text, action: action, duration: duration), signIn)
    }
}
