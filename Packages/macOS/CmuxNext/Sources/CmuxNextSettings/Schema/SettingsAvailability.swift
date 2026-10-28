/// What the Settings page and the settings palette leave out on this Mac now, on top of a row's
/// fixed ``SettingDescriptor/page`` and ``SettingDescriptor/palette`` exposure: rows whose feature is
/// off and choices this Mac cannot use (Energy Saver's "On Battery" on a Mac with no battery). The
/// schema export, write validation and `settings.set` keep every row and choice; only the two
/// surfaces that offer them to a person read this.
///
/// The App builds it from run-time facts (``EnergySaverSetting/availability(featureEnabled:hasBattery:)``)
/// and sends ``json`` in the Settings page's host lists.
public nonisolated struct SettingsAvailability: Sendable, Equatable {
    /// Setting ids (`energy.saver`) neither surface shows.
    public var hiddenRows: Set<String>
    /// Choice values each surface leaves out of a row, by setting id.
    public var hiddenChoices: [String: Set<String>]

    /// Hides `hiddenRows` and `hiddenChoices`; empty shows everything.
    public init(hiddenRows: Set<String> = [], hiddenChoices: [String: Set<String>] = [:]) {
        self.hiddenRows = hiddenRows
        self.hiddenChoices = hiddenChoices
    }

    /// Whether the surfaces offer `descriptor` now.
    public func isShown(_ descriptor: SettingDescriptor) -> Bool {
        !hiddenRows.contains(descriptor.id)
    }

    /// Whether the Settings page draws `descriptor` now: its fixed page exposure and this value both
    /// show it. Every entry point that names a page row asks this (the deep link's anchor, the
    /// diagnostic toast's Show in Settings), so none of them points at a row the page leaves out.
    public func isShownOnSettingsPage(_ descriptor: SettingDescriptor) -> Bool {
        descriptor.isShownOnSettingsPage && isShown(descriptor)
    }

    /// Whether `descriptor`'s choice `value` is offered now. The `current` value is always offered,
    /// so a row never shows a value the person cannot see selected.
    public func isShown(choice value: String, of descriptor: SettingDescriptor, current: JSONValue?) -> Bool {
        current?.stringValue == value || hiddenChoices[descriptor.id]?.contains(value) != true
    }

    /// The host lists' `availability`: `{"hidden_rows": [id], "hidden_choices": {id: [value]}}`, sorted.
    public var json: JSONValue {
        .object([
            "hidden_rows": .array(hiddenRows.sorted().map(JSONValue.string)),
            "hidden_choices": .object(hiddenChoices.filter { !$0.value.isEmpty }.mapValues { .array($0.sorted().map(JSONValue.string)) }),
        ])
    }
}
