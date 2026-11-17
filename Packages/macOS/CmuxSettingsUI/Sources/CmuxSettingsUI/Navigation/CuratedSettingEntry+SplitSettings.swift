import Foundation

extension CuratedSettingEntry {
    static var equalizeSplitsOnCreate: CuratedSettingEntry {
        .init(
            section: .app,
            id: "equalize-splits-on-create",
            title: String(localized: "settings.app.equalizeSplitsOnCreate", defaultValue: "Equalize Splits on Create"),
            synonyms: "app.equalizeSplitsOnCreate equalize balance distribute even equal split pane size new split"
        )
    }

    static var equalizeSplitsOnDividerDoubleClick: CuratedSettingEntry {
        .init(
            section: .app,
            id: "equalize-splits-on-divider-double-click",
            title: String(localized: "settings.app.equalizeSplitsOnDividerDoubleClick", defaultValue: "Equalize Splits on Divider Double-Click"),
            synonyms: "app.equalizeSplitsOnDividerDoubleClick equalize balance distribute even equal split pane size divider double click row column"
        )
    }
}
