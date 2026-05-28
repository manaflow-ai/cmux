import SwiftUI

/// Placeholder view used by every settings section that hasn't been
/// migrated from `Sources/cmuxApp.swift` yet.
///
/// Renders a "Coming soon" message identifying the section by title and
/// referencing the still-active legacy view. As migration proceeds,
/// individual placeholders are replaced by real ``AppSection``-style
/// views in `Sections/`.
@MainActor
public struct PlaceholderSection: View {
    private let sectionID: SettingsSectionID
    private let legacyViewSource: String

    public init(
        sectionID: SettingsSectionID,
        legacyViewSource: String
    ) {
        self.sectionID = sectionID
        self.legacyViewSource = legacyViewSource
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(sectionID.title, systemImage: sectionID.symbolName)
                .font(.title2)
                .padding(.top)
            Text("Not yet migrated to CmuxSettingsUI.")
                .foregroundStyle(.secondary)
            Text("Legacy implementation: \(legacyViewSource)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            Spacer()
        }
        .padding(.horizontal)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
