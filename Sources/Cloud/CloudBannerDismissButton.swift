import Foundation
import SwiftUI

/// A localized close affordance shared by persistent Cloud banners.
struct CloudBannerDismissButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 9, weight: .semibold))
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(String(localized: "common.close", defaultValue: "Close"))
        .accessibilityLabel(String(localized: "common.close", defaultValue: "Close"))
        .accessibilityIdentifier("CloudBannerDismissButton")
    }
}
