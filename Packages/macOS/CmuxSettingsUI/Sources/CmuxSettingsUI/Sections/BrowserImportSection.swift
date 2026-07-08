import CmuxSettings
import SwiftUI

/// **Import Browser Data** anchor — in the legacy layout the import
/// block is rendered inline inside the Browser section's card. This
/// section exists only as a navigation deeplink target; sidebar
/// clicks for `.browserImport` resolve to this view, which renders
/// nothing but the legacy import block (so deeplinks land near the
/// same content).
@MainActor
public struct BrowserImportSection: View {
    public init(
        defaultsStore: UserDefaultsSettingsStore,
        catalog: SettingCatalog,
        hostActions: SettingsHostActions
    ) {
        _ = defaultsStore
        _ = catalog
        _ = hostActions
    }

    public var body: some View {
        EmptyView()
    }
}
