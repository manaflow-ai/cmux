#if os(iOS)
import CmuxMobileSupport
import SwiftUI

/// A compact build-channel badge shared by visible and hidden computer rows.
struct ComputerBuildBadge: View {
    let label: String

    var body: some View {
        Text(label)
            .font(.caption2.weight(.semibold))
            .lineLimit(1)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(tint.opacity(0.18), in: Capsule())
            .foregroundStyle(tint)
            .accessibilityLabel(
                "\(L10n.string("mobile.computers.buildLabelPrefix", defaultValue: "Build:")) \(label)"
            )
    }

    private var tint: Color {
        if label.hasPrefix("DEV") || label == "RC" || label == "Staging" {
            return .orange
        }
        if label == "Nightly" {
            return .blue
        }
        return .secondary
    }
}
#endif
