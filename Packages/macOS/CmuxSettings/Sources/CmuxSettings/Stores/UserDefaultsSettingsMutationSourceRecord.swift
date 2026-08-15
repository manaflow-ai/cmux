/// Stores one source-tagged UserDefaults write for observer-local delivery.
struct UserDefaultsSettingsMutationSourceRecord: Sendable {
    let source: UserDefaultsSettingsMutationSource
    let sequence: UInt64
    private let value: any Sendable

    init<Value: SettingCodable>(
        source: UserDefaultsSettingsMutationSource,
        sequence: UInt64,
        value: Value
    ) {
        self.source = source
        self.sequence = sequence
        self.value = value
    }

    func matches<Value: SettingCodable>(_ value: Value) -> Bool {
        guard let recordedValue = self.value as? Value else { return false }
        return recordedValue == value
    }
}
