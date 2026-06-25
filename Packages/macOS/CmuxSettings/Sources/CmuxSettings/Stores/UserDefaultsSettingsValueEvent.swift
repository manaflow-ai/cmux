/// One observed `UserDefaults` setting value plus its optional mutation source.
public struct UserDefaultsSettingsValueEvent<Value: SettingCodable>: Sendable, Equatable {
    /// The decoded value for the observed key.
    public let value: Value

    /// The source attached to the latest store-owned write for the key, if any.
    public let mutationSource: UserDefaultsSettingsMutationSource?

    /// Creates an observed value event.
    public init(value: Value, mutationSource: UserDefaultsSettingsMutationSource? = nil) {
        self.value = value
        self.mutationSource = mutationSource
    }
}
