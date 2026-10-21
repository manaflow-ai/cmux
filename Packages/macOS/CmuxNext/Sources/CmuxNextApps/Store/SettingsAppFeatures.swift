public import CmuxNextSettings

/// The App Store Features tab's settings (``AppFeatureSettings``): reads the snapshot in
/// effect, so a card follows every writer (Settings, `cmux settings set`, an agent), and writes
/// through the schema-validated path with the person's authority (a button press on the page).
@MainActor
public final class SettingsAppFeatures: AppFeatureSettings {
    private let settings: () -> SettingsController?
    /// Shows Settings on a key's rows (the app's settings window); nil: the cards have no link.
    private let showSettings: (@MainActor (String) -> Void)?

    /// The sidebar's side of the `.sidebarItem` features, given by the sidebar's owner
    /// (`ChiefSidebar.bind`): the items it answers for, whether the sidebar shows one (observable),
    /// and Add to Sidebar or Remove Everywhere as the person's edit (false: refused).
    public struct SidebarItems {
        public var names: Set<String>
        public var isShown: @MainActor (String) -> Bool
        public var set: @MainActor (String, Bool) -> Bool

        public init(names: Set<String>, isShown: @escaping @MainActor (String) -> Bool, set: @escaping @MainActor (String, Bool) -> Bool) {
            self.names = names
            self.isShown = isShown
            self.set = set
        }
    }

    /// Nil until the sidebar binds its actions: no `.sidebarItem` feature is listed then.
    public static var sidebarItems: SidebarItems?

    public init(settings: @escaping () -> SettingsController?, showSettings: (@MainActor (String) -> Void)? = nil) {
        self.settings = settings
        self.showSettings = showSettings
    }

    /// Whether the card shows its Settings… link: the feature names rows and the app can show them.
    public func hasSettings(_ feature: AppFeature) -> Bool { feature.settingsLink != nil && showSettings != nil }

    public func openSettings(_ feature: AppFeature) {
        guard let key = feature.settingsLink else { return }
        showSettings?(key)
    }

    public func isAvailable(_ feature: AppFeature) -> Bool {
        if let item = feature.sidebarItem { return Self.sidebarItems?.names.contains(item) == true }
        return SettingsSchema.descriptor(for: feature.path) != nil
    }

    public func isOn(_ feature: AppFeature) -> Bool {
        if let item = feature.sidebarItem { return Self.sidebarItems?.isShown(item) == true }
        guard let settings = settings(), let descriptor = SettingsSchema.descriptor(for: feature.path) else { return false }
        return descriptor.effectiveValue(in: settings.snapshot.root) == Self.onValue(feature)
    }

    /// A sidebar item is the person's layout, never managed.
    public func isManaged(_ feature: AppFeature) -> Bool { feature.sidebarItem == nil && settings()?.managedKeys[feature.setting] != nil }

    public func set(_ feature: AppFeature, on: Bool) async throws {
        if let item = feature.sidebarItem {
            guard Self.sidebarItems?.set(item, on) == true else { throw SettingRefused(key: feature.setting, value: .string(item)) }
            return
        }
        guard let settings = settings(), let descriptor = SettingsSchema.descriptor(for: feature.path) else {
            throw SettingRefused(key: feature.setting, value: Self.onValue(feature))
        }
        try await settings.setSetting(descriptor, to: Self.value(feature, on: on, default: descriptor.defaultValue), by: .user)
    }

    /// The value that means on: `true`, or the feature's choice.
    nonisolated static func onValue(_ feature: AppFeature) -> JSONValue {
        switch feature.on {
        case .toggle: .bool(true)
        case .choice(let value), .sidebarItem(let value): .string(value)
        }
    }

    /// What Get (`on`) or Remove writes. Remove takes a choice key out of the file, so its
    /// default (off) applies; a toggle whose default is off leaves the file too, and one whose
    /// default is on is written `false`.
    nonisolated static func value(_ feature: AppFeature, on: Bool, default defaultValue: JSONValue?) -> JSONValue? {
        if on { return onValue(feature) }
        switch feature.on {
        case .toggle: return defaultValue == .bool(true) ? .bool(false) : nil
        case .choice, .sidebarItem: return nil
        }
    }
}
