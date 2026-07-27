#if os(iOS)
import SwiftUI
import UIKit

/// Owns the task composer's one initial UIKit focus transfer.
///
/// Architecture note: the prompt previously requested focus from its SwiftUI
/// `onAppear`, while the sheet presentation still owned responder readiness.
/// That split could make the keyboard start showing and then immediately hide.
/// This controller is now the single initial-focus owner. It waits for its
/// presentation lifecycle and an attached backing input, focuses once, then
/// permanently consumes the request for this sheet presentation. SwiftUI's
/// `FocusState` remains a visual mirror only.
struct TaskComposerInitialFocusCoordinator: UIViewControllerRepresentable {
    let isEnabled: Bool

    func makeUIViewController(context: Context) -> Controller {
        Controller(isEnabled: isEnabled)
    }

    func updateUIViewController(_ uiViewController: Controller, context: Context) {
        uiViewController.setEnabled(isEnabled)
    }

    @MainActor
    final class Controller: UIViewController {
        private enum Phase {
            case waitingForAppearance
            case waitingForInput
            case consumed
            case cancelled
        }

        private var phase: Phase = .waitingForAppearance
        private var isEnabled: Bool

        init(isEnabled: Bool) {
            self.isEnabled = isEnabled
            super.init(nibName: nil, bundle: nil)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func loadView() {
            let view = UIView(frame: .zero)
            view.isUserInteractionEnabled = false
            view.isAccessibilityElement = false
            view.accessibilityElementsHidden = true
            self.view = view
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            guard phase == .waitingForAppearance else { return }
            phase = .waitingForInput
            focusIfReady()
        }

        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            focusIfReady()
        }

        override func viewDidDisappear(_ animated: Bool) {
            if phase != .consumed {
                phase = .cancelled
            }
            super.viewDidDisappear(animated)
        }

        func setEnabled(_ isEnabled: Bool) {
            self.isEnabled = isEnabled
            if !isEnabled, phase != .consumed {
                phase = .cancelled
            }
        }

        private func focusIfReady() {
            guard isEnabled,
                  phase == .waitingForInput,
                  viewIfLoaded?.window != nil,
                  let input = promptInput() else { return }
            guard input.becomeFirstResponder() || input.isFirstResponder else { return }
            phase = .consumed
        }

        private func promptInput() -> UIView? {
            var container = parent?.view
            while let candidate = container {
                let inputs = candidate.taskComposerFocusableTextInputs()
                if let identified = inputs.first(where: {
                    $0.accessibilityIdentifier == "MobileTaskComposerPrompt"
                }) {
                    return identified
                }
                if inputs.count == 1 {
                    return inputs[0]
                }
                if let multilineInput = inputs.first(where: { $0 is UITextView }) {
                    return multilineInput
                }
                container = candidate.superview
            }
            return nil
        }
    }
}

private extension UIView {
    @MainActor
    func taskComposerFocusableTextInputs() -> [UIView] {
        var result: [UIView] = []
        if (self is UITextField || self is UITextView),
           canBecomeFirstResponder,
           window != nil,
           !isHidden,
           alpha > 0.01 {
            result.append(self)
        }
        for subview in subviews {
            result.append(contentsOf: subview.taskComposerFocusableTextInputs())
        }
        return result
    }
}
#endif
