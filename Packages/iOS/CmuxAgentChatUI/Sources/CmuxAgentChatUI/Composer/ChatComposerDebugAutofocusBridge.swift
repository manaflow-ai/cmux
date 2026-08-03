#if DEBUG && os(iOS)
import Foundation
import UIKit

/// Native, non-interactive debug marker that drives deterministic UI-test focus.
@MainActor
final class ChatComposerDebugAutofocusView: UIView {
    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        accessibilityElementsHidden = true
        scheduleAutofocus()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func scheduleAutofocus() {
        guard let delay = debugTimeInterval("CMUX_UITEST_CHAT_AUTOFOCUS_DELAY") else { return }
        UIView.animate(withDuration: 0, delay: Swift.max(0, delay), options: [.allowUserInteraction]) {
        } completion: { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let root = self.window ?? self.cmuxRootView()
                let input = root.cmuxFirstFocusableTextInput(preferredIdentifier: "ChatComposerField")
                _ = input?.becomeFirstResponder()
                self.scheduleDismissAndRefocus(for: input)
            }
        }
    }

    private func scheduleDismissAndRefocus(for input: UIView?) {
        guard let delay = debugTimeInterval("CMUX_UITEST_CHAT_AUTO_DISMISS_DELAY") else { return }
        UIView.animate(withDuration: 0, delay: Swift.max(0, delay), options: [.allowUserInteraction]) {
        } completion: { [weak self, weak input] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                input?.resignFirstResponder()
                guard let refocusDelay = self.debugTimeInterval(
                    "CMUX_UITEST_CHAT_AUTO_REFOCUS_AFTER_DISMISS_DELAY"
                ) else { return }
                UIView.animate(
                    withDuration: 0,
                    delay: Swift.max(0, refocusDelay),
                    options: [.allowUserInteraction]
                ) {
                } completion: { [weak input] _ in
                    MainActor.assumeIsolated {
                        _ = input?.becomeFirstResponder()
                    }
                }
            }
        }
    }

    private func debugTimeInterval(_ name: String) -> TimeInterval? {
        guard let raw = ProcessInfo.processInfo.environment[name]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !raw.isEmpty,
            let value = Double(raw)
        else { return nil }
        return value
    }
}

private extension UIView {
    func cmuxRootView() -> UIView {
        var current = self
        while let superview = current.superview {
            current = superview
        }
        return current
    }

    func cmuxFirstFocusableTextInput(preferredIdentifier: String) -> UIView? {
        if (self is UITextField || self is UITextView),
           canBecomeFirstResponder,
           accessibilityIdentifier == preferredIdentifier {
            return self
        }
        for subview in subviews {
            if let found = subview.cmuxFirstFocusableTextInput(preferredIdentifier: preferredIdentifier),
               found.accessibilityIdentifier == preferredIdentifier {
                return found
            }
        }
        if (self is UITextField || self is UITextView), canBecomeFirstResponder {
            return self
        }
        for subview in subviews {
            if let found = subview.cmuxFirstFocusableTextInput(preferredIdentifier: preferredIdentifier) {
                return found
            }
        }
        return nil
    }
}
#endif
