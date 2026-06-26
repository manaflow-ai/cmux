/// One observed `UserDefaults` setting value plus its optional mutation source.
public struct UserDefaultsSettingsValueEvent<Value: SettingCodable>: Sendable, Equatable {
    /// The decoded value for the observed key.
    public let value: Value

    /// One-shot source attached to this observed store-owned write, if any.
    public let mutationSource: UserDefaultsSettingsMutationSource?

    /// Pending source whose stored value was overwritten before observation.
    public let supersededMutationSource: UserDefaultsSettingsMutationSource?

    /// Creates an observed value event.
    public init(
        value: Value,
        mutationSource: UserDefaultsSettingsMutationSource? = nil,
        supersededMutationSource: UserDefaultsSettingsMutationSource? = nil
    ) {
        self.value = value
        self.mutationSource = mutationSource
        self.supersededMutationSource = supersededMutationSource
    }
}
