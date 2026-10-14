import SwiftUI

struct KeyboardNavigationModeIndicator: View {
    let modeName: String

    private var label: String {
        String.localizedStringWithFormat(
            String(localized: "shortcut.navigationMode.active", defaultValue: "Navigation mode: %@"),
            modeName
        )
    }

    var body: some View {
        Label(label, systemImage: "arrow.up.and.down.and.arrow.left.and.right")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.primary)
            .lineLimit(1)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(Color.accentColor.opacity(0.45), lineWidth: 1))
            .padding(.top, 10)
            .padding(.leading, 10)
            .allowsHitTesting(false)
            .accessibilityLabel(label)
    }
}
