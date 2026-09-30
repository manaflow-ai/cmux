import Foundation

extension UserDefaultsSettingsClient {
    /// The effective value of a sidebar detail toggle.
    ///
    /// An explicitly stored value wins. Otherwise the current
    /// ``SidebarDensity`` supplies the value, and the catalog default applies
    /// when the density leaves the toggle alone.
    public func sidebarDetailValue(for key: DefaultsKey<Bool>) -> Bool {
        if let stored = valueIfPresent(for: key) {
            return stored
        }
        let density = value(for: SidebarCatalogSection().density)
        return density.presetValue(forSettingID: key.id) ?? key.defaultValue
    }

    /// The effective notification preview line limit, before range clamping.
    ///
    /// An explicitly stored limit wins over the density's limit.
    public func sidebarNotificationMessageLineLimit() -> Int {
        let key = SidebarCatalogSection().notificationMessageLineLimit
        if let stored = valueIfPresent(for: key) {
            return stored
        }
        let density = value(for: SidebarCatalogSection().density)
        return density.notificationMessageLineLimit ?? key.defaultValue
    }
}
