import AppKit
import SwiftUI

/// Right-side titlebar accessory hosting the iPhone button that opens the
/// Mobile Connect (phone pairing) window. Installed per main terminal
/// window by `UpdateTitlebarAccessoryController` alongside the left-side
/// controls accessory; visibility in minimal mode and fullscreen is managed
/// there. The button itself is gated on
/// ``CmuxFeatureFlags/isMobileConnectButtonEnabled`` inside the SwiftUI
/// view, so a PostHog toggle applies live without re-attaching accessories.
final class MobileConnectTitlebarAccessoryViewController: NSTitlebarAccessoryViewController {
    init() {
        super.init(nibName: nil, bundle: nil)
        layoutAttribute = .right
        let hosting = NSHostingView(rootView: TitlebarTrailingControls())
        hosting.setContentHuggingPriority(.required, for: .horizontal)
        view = hosting
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }
}

/// Trailing titlebar cluster. Mobile Connect now lives in the sidebar footer.
private struct TitlebarTrailingControls: View {
    var body: some View {
        ProBadgeView()
            .padding(.trailing, 8)
    }
}
