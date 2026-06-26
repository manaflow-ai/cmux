import SwiftUI
import Foundation

/// One permission row in the extension details popover: a granted/pending
/// status glyph, the scope's name and description, and a trailing
/// granted/pending label.
///
/// A pure presentation leaf: it holds no app-target state. The `title` and
/// `detail` are the already-resolved scope display name and description, and
/// `isGranted` selects the glyph, tint, and trailing label. The trailing label
/// is localized with `bundle: .main` so the keys resolve against the app
/// bundle's catalog (including Japanese), matching the original app-side
/// `String(localized:)` lookup.
struct ExtensionPermissionRow: View {
    let title: String
    let detail: String
    let isGranted: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: isGranted ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(isGranted ? .green : .secondary)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 11, weight: .medium))
                Text(detail)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Text(isGranted
                ? String(localized: "sidebar.extensions.details.granted", defaultValue: "Granted", bundle: .main)
                : String(localized: "sidebar.extensions.details.pending", defaultValue: "Pending", bundle: .main))
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
        }
    }
}
