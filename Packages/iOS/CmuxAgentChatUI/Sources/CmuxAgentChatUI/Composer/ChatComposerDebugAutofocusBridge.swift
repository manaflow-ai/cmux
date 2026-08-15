#if DEBUG && os(iOS)
import Foundation
import SwiftUI
import UIKit

struct ChatComposerDebugAutofocusBridge: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: .zero)
        view.isUserInteractionEnabled = false
        view.isAccessibilityElement = false
        view.accessibilityElementsHidden = true
        scheduleChatComposerDebugAutofocus(from: view)
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {}

    @MainActor
    private func scheduleChatComposerDebugAutofocus(from view: UIView) {
        guard let delay = chatComposerDebugTimeInterval("CMUX_UITEST_CHAT_AUTOFOCUS_DELAY") else {
            return
        }
        UIView.animate(withDuration: 0, delay: max(0, delay), options: [.allowUserInteraction]) {
        } completion: { _ in
            MainActor.assumeIsolated {
                let root = view.window ?? view.cmuxRootView()
                let input = root.cmuxFirstFocusableTextInput(preferredIdentifier: "ChatComposerField")
                _ = input?.becomeFirstResponder()
                scheduleChatComposerDebugDismissAndRefocus(for: input)
            }
        }
    }

    @MainActor
    private func scheduleChatComposerDebugDismissAndRefocus(for input: UIView?) {
        guard let autoDismissDelay = chatComposerDebugTimeInterval("CMUX_UITEST_CHAT_AUTO_DISMISS_DELAY") else {
            return
        }
        UIView.animate(withDuration: 0, delay: max(0, autoDismissDelay), options: [.allowUserInteraction]) {
        } completion: { _ in
            MainActor.assumeIsolated {
                input?.resignFirstResponder()
                guard let autoRefocusDelay = chatComposerDebugTimeInterval("CMUX_UITEST_CHAT_AUTO_REFOCUS_AFTER_DISMISS_DELAY") else {
                    return
                }
                UIView.animate(withDuration: 0, delay: max(0, autoRefocusDelay), options: [.allowUserInteraction]) {
                } completion: { _ in
                    MainActor.assumeIsolated {
                        _ = input?.becomeFirstResponder()
                    }
                }
            }
        }
    }

    private func chatComposerDebugTimeInterval(_ name: String) -> TimeInterval? {
        guard let raw = ProcessInfo.processInfo.environment[name]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !raw.isEmpty,
            let value = Double(raw)
        else {
            return nil
        }
        return value
    }
}

private extension UIView {
    @MainActor
    func cmuxRootView() -> UIView {
        var current = self
        while let superview = current.superview {
            current = superview
        }
        return current
    }

    @MainActor
    func cmuxFirstFocusableTextInput(preferredIdentifier: String) -> UIView? {
        if (self is UITextField || self is UITextView), canBecomeFirstResponder {
            if accessibilityIdentifier == preferredIdentifier {
                return self
            }
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
