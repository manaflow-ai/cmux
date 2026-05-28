import CmuxSettings
import SwiftUI

/// SwiftUI view for the **Account** section.
///
/// The full account UI in the existing app (`Sources/Auth/`) handles
/// sign-in flows, team selection, PII display mode, and cached user
/// fetches against the cmux backend. None of that lives in
/// ``CmuxSettings`` yet because it depends on the app's `CMUXAuthCore`
/// package and SwiftUI navigation flows that are out of scope for the
/// settings-storage refactor.
///
/// For now, this view explains the gap and links to the legacy
/// implementation. The migration target is to move the small set of
/// auth-related preferences (PII display mode, selected team ID,
/// cached user JSON) into a `AccountCatalogSection` and rebuild the
/// sign-in / sign-out controls in this view.
public struct AccountSection: View {
    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Account", systemImage: "person.crop.circle")
                .font(.title2)
                .padding(.top)
            Text("Account preferences (team, PII display, cached user) still live in `Sources/Auth/AuthSettingsStore.swift`. The full sign-in / sign-out flow uses `CMUXAuthCore` and is not part of the settings-storage refactor.")
                .foregroundStyle(.secondary)
            Text("Migration target: introduce `AccountCatalogSection` for the small set of UserDefaults-backed account preferences and rebuild this view against it.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .textSelection(.enabled)
            Spacer()
        }
        .padding(.horizontal)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
