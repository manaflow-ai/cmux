#if os(iOS) && DEBUG
import Foundation
import SwiftUI
import UIKit

struct ChatComposerDebugAutofocusBridge: UIViewRepresentable {
    let delay: TimeInterval?

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: .zero)
        view.isUserInteractionEnabled = false
        view.isAccessibilityElement = false
        view.accessibilityElementsHidden = true
        context.coordinator.view = view
        context.coordinator.schedule(delay: delay)
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.view = uiView
        context.coordinator.schedule(delay: delay)
    }

    @MainActor
    final class Coordinator {
        weak var view: UIView?
        private var didSchedule = false

        func schedule(delay: TimeInterval?) {
            guard !didSchedule, let delay else { return }
            didSchedule = true
            let nanoseconds = UInt64(max(0, delay) * 1_000_000_000)
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: nanoseconds)
                guard !Task.isCancelled, let view = self?.view else { return }
                let root = view.window ?? view.cmuxRootView()
                let input = root.cmuxFirstFocusableTextInput(preferredIdentifier: "ChatComposerField")
                let didFocus = input?.becomeFirstResponder() ?? false
                NSLog(
                    "cmux.chat.autofocus bridge input=%@ canBecome=%d didFocus=%d isFirst=%d",
                    input.map { String(describing: type(of: $0)) } ?? "nil",
                    input?.canBecomeFirstResponder == true ? 1 : 0,
                    didFocus ? 1 : 0,
                    input?.isFirstResponder == true ? 1 : 0
                )
                if let autoDismissDelay = Self.autoDismissDelay {
                    let dismissNanoseconds = UInt64(max(0, autoDismissDelay) * 1_000_000_000)
                    Task { @MainActor [weak input] in
                        try? await Task.sleep(nanoseconds: dismissNanoseconds)
                        guard !Task.isCancelled else { return }
                        input?.resignFirstResponder()
                        if let autoRefocusDelay = Self.autoRefocusAfterDismissDelay {
                            let refocusNanoseconds = UInt64(max(0, autoRefocusDelay) * 1_000_000_000)
                            try? await Task.sleep(nanoseconds: refocusNanoseconds)
                            guard !Task.isCancelled else { return }
                            _ = input?.becomeFirstResponder()
                        }
                    }
                }
            }
        }

        private static var autoDismissDelay: TimeInterval? {
            guard let raw = ProcessInfo.processInfo.environment["CMUX_UITEST_CHAT_AUTO_DISMISS_DELAY"]?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                !raw.isEmpty,
                let value = Double(raw)
            else {
                return nil
            }
            return value
        }

        private static var autoRefocusAfterDismissDelay: TimeInterval? {
            guard let raw = ProcessInfo.processInfo.environment["CMUX_UITEST_CHAT_AUTO_REFOCUS_AFTER_DISMISS_DELAY"]?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                !raw.isEmpty,
                let value = Double(raw)
            else {
                return nil
            }
            return value
        }
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
