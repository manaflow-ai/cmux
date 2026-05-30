import SwiftUI

/// Section header rendered above a ``SettingsCard``.
///
/// Mirrors the legacy in-app chrome: small secondary-colored title
/// nudged 2pt right of the card, intentionally tucked close to the
/// card below it. Use ``settingsSearchAnchor(_:)`` on the header
/// when callers should be able to scroll-to it from the sidebar
/// or the search hit list.
@MainActor
public struct SettingsSectionHeader: View {
    let title: String

    public init(_ title: String) {
        self.title = title
    }

    public var body: some View {
        Text(title)
            .font(.system(size: 13, weight: .semibold))
            .foregroundColor(.secondary)
            .padding(.leading, 2)
            .padding(.bottom, -2)
    }
}
