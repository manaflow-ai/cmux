#if os(iOS)
import SwiftUI
import UIKit

/// Installs a window-level tap recognizer that dismisses the keyboard when
/// the user taps anywhere outside the focused field (Telegram / WhatsApp
/// behavior).
///
/// The recognizer sets `cancelsTouchesInView = false` and
/// `delaysTouchesEnded = false`, so taps still reach buttons and rows below
/// it; it only ends editing as a side effect. Use via
/// ``SwiftUI/View/dismissesKeyboardOnTap()``.
struct KeyboardDismissTap: UIViewRepresentable {
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.isUserInteractionEnabled = false
        context.coordinator.attach(from: view)
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        // The window may not exist at make time (off-screen mount); retry.
        context.coordinator.attach(from: uiView)
    }

    /// Owns the recognizer and forwards taps to `endEditing`.
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        private weak var installedWindow: UIWindow?
        private lazy var recognizer: UITapGestureRecognizer = {
            let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap))
            tap.cancelsTouchesInView = false
            tap.delaysTouchesEnded = false
            tap.delegate = self
            return tap
        }()

        func attach(from view: UIView) {
            guard let window = view.window, window !== installedWindow else { return }
            installedWindow?.removeGestureRecognizer(recognizer)
            window.addGestureRecognizer(recognizer)
            installedWindow = window
        }

        @objc private func handleTap() {
            installedWindow?.endEditing(true)
        }

        // Never swallow touches from other recognizers (scrolling, buttons).
        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
        ) -> Bool {
            true
        }
    }
}

extension View {
    /// Dismisses the keyboard when the user taps outside the focused field,
    /// without blocking taps on buttons or rows.
    func dismissesKeyboardOnTap() -> some View {
        background(KeyboardDismissTap().allowsHitTesting(false))
    }
}
#endif
