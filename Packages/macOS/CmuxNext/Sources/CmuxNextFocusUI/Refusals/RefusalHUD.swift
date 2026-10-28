package import AppKit
package import CmuxNextDesign

/// Why a keyboard or menu action refused ("Not enough room to split this
/// column"), instead of a bare beep: a toast in the active window through
/// the one toast component (`CmuxToastCenter`), so it looks, stacks and
/// holds under the pointer like every other toast. A newer refusal replaces
/// the one showing.
@MainActor
package final class RefusalHUD {
    package static let toastID = "refusal"
    private let toasts: CmuxToastCenter
    private var handle: CmuxToastHandle?
    /// How long a message stays.
    package var lifetime: Duration = .seconds(4)

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
        handle = toasts.show(CmuxToast(id: Self.toastID, message: text, duration: lifetime), in: window)
    }
}
