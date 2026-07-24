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

/// Trailing titlebar cluster: the Pro badge (active ``ProBadgeStyle``)
/// followed by the Mobile Connect iPhone button.
private struct TitlebarTrailingControls: View {
    var body: some View {
        HStack(spacing: 4) {
            ProBadgeView()
            MobileConnectTitlebarButton()
        }
        .padding(.trailing, 8)
    }
}

private struct MobileConnectTitlebarButton: View {
    @State private var isHovered = false

    private var helpTitle: String {
        String(localized: "command.mobileConnect.title", defaultValue: "Connect iPhone/iPad")
    }

    var body: some View {
        if CmuxFeatureFlags.shared.isMobileConnectButtonEnabled {
            Button {
                MobilePairingWindowController.shared.show()
            } label: {
                Image(systemName: "iphone")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                    .frame(width: 24, height: 22, alignment: .center)
                    .background(
                        RoundedRectangle(cornerRadius: 5)
                            .fill(isHovered ? Color(nsColor: .quaternaryLabelColor) : .clear)
                    )
            }
            .buttonStyle(.plain)
            .onHover { isHovered = $0 }
            .safeHelp(helpTitle)
            .accessibilityLabel(helpTitle)
            .accessibilityIdentifier("TitlebarMobileConnectButton")
        }
    }
}
