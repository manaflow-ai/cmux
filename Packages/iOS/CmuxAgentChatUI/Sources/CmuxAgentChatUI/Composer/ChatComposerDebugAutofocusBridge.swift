#if os(iOS)
import Darwin
import Foundation
import SwiftUI
import UIKit

struct ChatComposerDebugAutofocusBridge: UIViewRepresentable {
    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: .zero)
        view.isUserInteractionEnabled = false
        view.isAccessibilityElement = false
        view.accessibilityElementsHidden = true
        context.coordinator.view = view
        context.coordinator.schedule()
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.view = uiView
        context.coordinator.schedule()
    }

    @MainActor
    final class Coordinator {
        weak var view: UIView?
        private var didSchedule = false

        func schedule() {
            guard !didSchedule, let delay = Self.timeInterval("CMUX_UITEST_CHAT_AUTOFOCUS_DELAY") else {
                return
            }
            didSchedule = true
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(Self.remainingDelaySinceProcessLaunch(delay)))
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
                await Self.scheduleDismissAndRefocus(for: input)
            }
        }

        private static func scheduleDismissAndRefocus(for input: UIView?) async {
            guard let autoDismissDelay = timeInterval("CMUX_UITEST_CHAT_AUTO_DISMISS_DELAY") else {
                return
            }
            try? await Task.sleep(for: .seconds(max(0, autoDismissDelay)))
            guard !Task.isCancelled else { return }
            input?.resignFirstResponder()
            guard let autoRefocusDelay = timeInterval("CMUX_UITEST_CHAT_AUTO_REFOCUS_AFTER_DISMISS_DELAY") else {
                return
            }
            try? await Task.sleep(for: .seconds(max(0, autoRefocusDelay)))
            guard !Task.isCancelled else { return }
            _ = input?.becomeFirstResponder()
        }

        private static func timeInterval(_ name: String) -> TimeInterval? {
            guard let raw = ProcessInfo.processInfo.environment[name]?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                !raw.isEmpty,
                let value = Double(raw)
            else {
                return nil
            }
            return value
        }

        private static func remainingDelaySinceProcessLaunch(_ delay: TimeInterval) -> TimeInterval {
            guard let elapsed = elapsedSinceProcessLaunch else {
                return max(0, delay)
            }
            return max(0, delay - elapsed)
        }

        private static var elapsedSinceProcessLaunch: TimeInterval? {
            var mib = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
            var info = kinfo_proc()
            var size = MemoryLayout<kinfo_proc>.stride
            guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0 else {
                return nil
            }
            let startedAt = TimeInterval(info.kp_proc.p_starttime.tv_sec)
                + TimeInterval(info.kp_proc.p_starttime.tv_usec) / 1_000_000
            return Date().timeIntervalSince1970 - startedAt
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
