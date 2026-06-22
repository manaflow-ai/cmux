import CmuxFoundation
import SwiftUI

/// Section header rendered above a ``SettingsCard``.
///
/// Mirrors the legacy in-app chrome: small secondary-colored title
/// nudged 2pt right of the card, intentionally tucked close to the
/// card below it.
///
/// Pass the owning ``SettingsSectionID`` so the header pulses the
/// search-result highlight when the user clicks that section's hit in
/// the sidebar search (matching the per-row highlight). The scroll
/// `.id` stays on the enclosing section, so the header only takes the
/// highlight overlay, never a duplicate `.id`.
@MainActor
public struct SettingsSectionHeader: View {
    let title: String
    let section: SettingsSectionID?

    public init(_ title: String, section: SettingsSectionID? = nil) {
        self.title = title
        self.section = section
    }

    public var body: some View {
        Text(title)
            .cmuxFont(size: 13, weight: .semibold)
            .foregroundColor(.secondary)
            .padding(.leading, 2)
            .padding(.bottom, -2)
            .settingsSearchHighlight(section.map { ["section:\($0.rawValue)"] } ?? [])
    }
}
