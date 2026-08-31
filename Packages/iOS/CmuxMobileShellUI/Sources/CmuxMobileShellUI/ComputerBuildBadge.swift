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

/// The compact "Update required" marker for a computer whose pairing this
/// build refuses to dial until cmux on the Mac updates
/// (``MacComputerSnapshot/needsMacUpdate``). Ambient and non-modal by design
/// (HIG: communicate a problem in context instead of an alert); the full
/// explanation lives in the computer's detail view.
struct ComputerUpdateRequiredBadge: View {
    var body: some View {
        // Explicit HStack instead of Label: the default label style leaves a
        // visibly loose gap between the glyph and the text at caption size.
        HStack(spacing: 4) {
            Image(systemName: "exclamationmark.triangle.fill")
                .imageScale(.small)
            Text(L10n.string(
                "mobile.computers.updateRequiredBadge",
                defaultValue: "Update required"
            ))
        }
        .font(.caption2.weight(.semibold))
        .lineLimit(1)
        // The warning must never compress into a meaningless fragment when
        // the title row is crowded; the computer name truncates instead.
        .fixedSize()
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Color.orange.opacity(0.18), in: Capsule())
        .foregroundStyle(.orange)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("MobileComputerUpdateRequiredBadge")
    }
}
#endif
