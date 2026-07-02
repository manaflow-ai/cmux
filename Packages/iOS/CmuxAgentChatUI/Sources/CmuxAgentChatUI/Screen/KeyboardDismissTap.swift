#if os(iOS)
import SwiftUI
import UIKit

/// Installs a window-level tap recognizer that dismisses the keyboard when
/// the user taps inside a specific region (the chat transcript), matching
/// Telegram / WhatsApp: tapping the conversation dismisses the keyboard, but
/// tapping the composer, the accessory bar, or the header does not.
///
/// The recognizer must live on the window so it can see taps that land on the
/// scrolling transcript content in front of this background view; a delegate
/// then restricts it to the `dismissRegion` (the transcript's frame in window
/// coordinates) so taps outside that region are ignored. It sets
/// `cancelsTouchesInView = false`, so taps still reach rows and buttons; it
/// only resigns the first responder as a side effect. Use via
/// ``SwiftUI/View/dismissesKeyboardOnTap(in:)``.
struct KeyboardDismissTap: UIViewRepresentable {
    /// The only region whose taps dismiss the keyboard, in global/window
    /// coordinates. Taps above it (header) or below it (composer, accessory
    /// bar, keyboard) are ignored. `.zero` dismisses nowhere.
    var dismissRegion: CGRect

    /// A region inside `dismissRegion` whose taps must NOT dismiss — the
    /// floating scroll-to-bottom button sits over the transcript but is a
    /// control, so tapping it should scroll, not dismiss. `.zero` excludes
    /// nothing.
    var excludedRegion: CGRect = .zero

    func makeUIView(context: Context) -> TapInstallerView { TapInstallerView() }

    func updateUIView(_ uiView: TapInstallerView, context: Context) {
        uiView.dismissRegion = dismissRegion
        uiView.excludedRegion = excludedRegion
    }

    /// A non-interactive marker view that adds the recognizer to its window
    /// in `didMoveToWindow` — the only reliable "I'm in a window now" hook
    /// (relying on `updateUIView` timing missed the attach when no input
    /// changed after mount, so the first version never fired).
    @MainActor
    final class TapInstallerView: UIView {
        /// Region (window coords) whose taps dismiss the keyboard.
        var dismissRegion: CGRect = .zero

        /// Region (window coords) whose taps are excluded (the scroll button).
        var excludedRegion: CGRect = .zero

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
            // Detaching (window == nil) or moving windows must REMOVE the
            // recognizer from the old window — otherwise it outlives the chat
            // and dismisses the keyboard on every tap across other screens
            // that share the window.
            if window !== installedWindow {
                installedWindow?.removeGestureRecognizer(recognizer)
                installedWindow = nil
            }
            guard let window else { return }
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
    // Only recognize taps that land inside the transcript region, so tapping
    // the composer / accessory bar / header never dismisses the keyboard.
    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldReceive touch: UITouch
    ) -> Bool {
        guard !dismissRegion.isEmpty, let window else { return false }
        let point = touch.location(in: window)
        guard dismissRegion.contains(point) else { return false }
        return !excludedRegion.contains(point)
    }

    // Never block other recognizers (scrolling, buttons, row taps).
    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
    ) -> Bool {
        true
    }
}

/// Reports the chat transcript's frame (window coordinates) up to the screen
/// so the keyboard-dismiss recognizer can restrict itself to that region.
struct ChatTranscriptFramePreferenceKey: PreferenceKey {
    static let defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let next = nextValue()
        if next != .zero { value = next }
    }
}

/// Reports the composer's frame (window coordinates), so the transcript
/// dismiss region can be clipped to end at the composer's top edge — the
/// transcript view itself extends under the composer's safe-area inset.
struct ChatComposerFramePreferenceKey: PreferenceKey {
    static let defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let next = nextValue()
        if next != .zero { value = next }
    }
}

/// Reports the floating scroll-to-bottom button's frame (window coordinates)
/// so the dismiss recognizer can exclude it (tapping it scrolls, not
/// dismisses).
struct ChatScrollButtonFramePreferenceKey: PreferenceKey {
    static let defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let next = nextValue()
        if next != .zero { value = next }
    }
}

extension View {
    /// Publishes this control's frame so the keyboard-dismiss tap excludes it.
    /// The scroll button extends its hit area 3pt beyond its frame
    /// (`contentShape(Circle().inset(by: -3))`); match that here so a tap in
    /// the halo scrolls without also dismissing the keyboard.
    func excludedFromKeyboardDismiss() -> some View {
        background(
            GeometryReader { proxy in
                Color.clear.preference(
                    key: ChatScrollButtonFramePreferenceKey.self,
                    value: proxy.frame(in: .global).insetBy(dx: -3, dy: -3)
                )
            }
        )
    }

    /// Marks this view as the chat-history region: publishes its frame so the
    /// dismiss recognizer fires only here.
    func chatTranscriptDismissRegion() -> some View {
        background(
            GeometryReader { proxy in
                Color.clear.preference(
                    key: ChatTranscriptFramePreferenceKey.self,
                    value: proxy.frame(in: .global)
                )
            }
        )
    }

    /// Publishes the composer's frame so the dismiss region can exclude it.
    func reportsChatComposerFrame() -> some View {
        background(
            GeometryReader { proxy in
                Color.clear.preference(
                    key: ChatComposerFramePreferenceKey.self,
                    value: proxy.frame(in: .global)
                )
            }
        )
    }

    /// Dismisses the keyboard when the user taps inside `region` (the chat
    /// transcript), without blocking taps on buttons or rows, and without
    /// dismissing on taps in the composer, accessory bar, header, or the
    /// `excluding` region (the scroll-to-bottom button).
    func dismissesKeyboardOnTap(in region: CGRect, excluding: CGRect) -> some View {
        background(KeyboardDismissTap(dismissRegion: region, excludedRegion: excluding))
    }
}
#endif
