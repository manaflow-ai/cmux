#if os(iOS)
import SwiftUI
import UIKit

/// Installs a window-level tap recognizer that dismisses the keyboard when
/// the user taps anywhere outside the focused field (Telegram / WhatsApp
/// behavior).
///
/// The recognizer sets `cancelsTouchesInView = false` and
/// `delaysTouchesEnded = false`, so taps still reach buttons and rows below
/// it; it only resigns the first responder as a side effect. Use via
/// ``SwiftUI/View/dismissesKeyboardOnTap()``.
struct KeyboardDismissTap: UIViewRepresentable {
    func makeUIView(context: Context) -> TapInstallerView { TapInstallerView() }
    func updateUIView(_ uiView: TapInstallerView, context: Context) {}

    /// A non-interactive marker view that adds the recognizer to its window
    /// in `didMoveToWindow` — the only reliable "I'm in a window now" hook
    /// (relying on `updateUIView` timing missed the attach when no input
    /// changed after mount, so the first version never fired).
    final class TapInstallerView: UIView {
        private weak var installedWindow: UIWindow?

        private lazy var recognizer: UITapGestureRecognizer = {
            let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap))
            tap.cancelsTouchesInView = false
            tap.delaysTouchesEnded = false
            tap.delegate = self
            return tap
        }()

        override init(frame: CGRect) {
            super.init(frame: frame)
            isUserInteractionEnabled = false
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("not used in storyboards") }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard let window, window !== installedWindow else { return }
            installedWindow?.removeGestureRecognizer(recognizer)
            window.addGestureRecognizer(recognizer)
            installedWindow = window
        }

        @objc private func handleTap() {
            // Resign whoever holds the keyboard, app-wide; robust regardless
            // of which window/responder owns it.
            UIApplication.shared.sendAction(
                #selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil
            )
        }
    }
}

extension KeyboardDismissTap.TapInstallerView: UIGestureRecognizerDelegate {
    // Never block other recognizers (scrolling, buttons, row taps).
    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
    ) -> Bool {
        true
    }
}

extension View {
    /// Dismisses the keyboard when the user taps outside the focused field,
    /// without blocking taps on buttons or rows.
    func dismissesKeyboardOnTap() -> some View {
        background(KeyboardDismissTap())
    }
}
#endif
