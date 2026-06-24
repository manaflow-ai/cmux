#if os(iOS)
import CmuxMobileSupport
import SwiftUI
import UIKit

/// Moves the chat transcript/composer stack with the software keyboard.
///
/// SwiftUI's default keyboard avoidance can translate a focused field without
/// changing the embedded `UITableView`'s frame. This modifier opts the chat root
/// out of that implicit avoidance and applies an explicit bottom reservation,
/// driven by `UIKeyboardWillChangeFrame`, so the transcript's actual bounds
/// shrink while the composer rides the keyboard edge.
struct ChatKeyboardTrackingLayout: ViewModifier {
    @State private var bottomReservation: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.bottom, bottomReservation)
            .ignoresSafeArea(.keyboard, edges: .bottom)
            .background(ChatKeyboardTransitionObserver(bottomReservation: $bottomReservation))
    }
}

private struct ChatKeyboardTransitionObserver: UIViewRepresentable {
    @Binding var bottomReservation: CGFloat

    func makeCoordinator() -> Coordinator {
        Coordinator(bottomReservation: $bottomReservation)
    }

    func makeUIView(context: Context) -> ObserverView {
        ObserverView(coordinator: context.coordinator)
    }

    func updateUIView(_ uiView: ObserverView, context: Context) {
        context.coordinator.bottomReservation = $bottomReservation
    }

    @MainActor
    final class Coordinator {
        var bottomReservation: Binding<CGFloat>

        init(bottomReservation: Binding<CGFloat>) {
            self.bottomReservation = bottomReservation
        }

        func apply(_ transition: MobileKeyboardTransition, in view: UIView) {
            let reservation = transition.overlap(in: view)
            guard abs(reservation - bottomReservation.wrappedValue) > 0.5 else { return }
            transition.animate {
                withAnimation(transition.chatSwiftUIAnimation) {
                    self.bottomReservation.wrappedValue = reservation
                }
                view.superview?.layoutIfNeeded()
                view.window?.layoutIfNeeded()
            }
        }
    }

    final class ObserverView: UIView {
        private weak var coordinator: Coordinator?

        init(coordinator: Coordinator) {
            self.coordinator = coordinator
            super.init(frame: .zero)
            isUserInteractionEnabled = false
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(keyboardWillChangeFrame),
                name: UIResponder.keyboardWillChangeFrameNotification,
                object: nil
            )
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("not used in storyboards") }

        deinit {
            NotificationCenter.default.removeObserver(self)
        }

        @objc private func keyboardWillChangeFrame(_ notification: Notification) {
            guard window != nil,
                  let transition = MobileKeyboardTransition(notification: notification)
            else { return }
            coordinator?.apply(transition, in: self)
        }
    }
}

private extension MobileKeyboardTransition {
    var chatSwiftUIAnimation: Animation {
        guard duration > 0 else { return .linear(duration: 0) }
        let rawCurve = Int(animationOptions.rawValue >> 16)
        guard let curve = UIView.AnimationCurve(rawValue: rawCurve) else {
            return .easeOut(duration: duration)
        }
        switch curve {
        case .easeInOut:
            return .timingCurve(0.42, 0, 0.58, 1, duration: duration)
        case .easeIn:
            return .timingCurve(0.42, 0, 1, 1, duration: duration)
        case .easeOut:
            return .timingCurve(0, 0, 0.58, 1, duration: duration)
        case .linear:
            return .linear(duration: duration)
        @unknown default:
            return .easeOut(duration: duration)
        }
    }
}
#endif
