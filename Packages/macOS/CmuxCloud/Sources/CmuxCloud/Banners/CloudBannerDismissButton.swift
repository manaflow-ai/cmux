import Foundation
import SwiftUI

/// A localized close affordance shared by persistent Cloud banners.
public struct CloudBannerDismissButton: View {
    public init(
        action: @escaping () -> Void
    ) {
        self.action = action
    }

    public let action: () -> Void
    @State private var isHovered = false

    public var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 9, weight: .semibold))
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(isHovered ? .primary : .secondary)
        // The Cloud sidebar's icon-button hover (`MachinesChromeIconButton`):
        // a faint fill in the sidebar's 6 pt button shape.
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isHovered ? Color.primary.opacity(0.06) : Color.clear)
        )
        .onHover { isHovered = $0 }
        .help(String(localized: "common.close", defaultValue: "Close"))
        .accessibilityLabel(String(localized: "common.close", defaultValue: "Close"))
        .accessibilityIdentifier("CloudBannerDismissButton")
    }
}
