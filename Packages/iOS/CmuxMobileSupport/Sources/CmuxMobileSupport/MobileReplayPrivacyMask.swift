#if os(iOS)
public import SwiftUI

/// Covers private SwiftUI content with a replay-only mask, without intercepting touches.
public struct MobileReplayPrivacyMask: UIViewRepresentable {
    /// Creates a mask sized by its containing overlay.
    public init() {}

    /// Creates the transparent view recognized by the app's replay configuration.
    public func makeUIView(context: Context) -> MobileReplayPrivacyMaskView {
        let view = MobileReplayPrivacyMaskView()
        view.backgroundColor = .clear
        view.isOpaque = false
        view.isUserInteractionEnabled = false
        view.accessibilityElementsHidden = true
        return view
    }

    /// The mask has no content or mutable state.
    public func updateUIView(_ uiView: MobileReplayPrivacyMaskView, context: Context) {}
}
#endif
