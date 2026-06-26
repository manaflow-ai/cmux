/// One observed `UserDefaults` setting value plus its optional mutation source.
public struct UserDefaultsSettingsValueEvent<Value: SettingCodable>: Sendable, Equatable {
    /// The decoded value for the observed key.
    public let value: Value

    /// One-shot source attached to this observed store-owned write, if any.
    public let mutationSource: UserDefaultsSettingsMutationSource?

    /// Source whose stored value was overwritten before observation emitted it.
    public let supersededMutationSource: UserDefaultsSettingsMutationSource?

    /// Whether this event is the stream's initial store snapshot.
    public let isInitialSnapshot: Bool

    /// Creates an observed value event.
    public init(
        value: Value,
        mutationSource: UserDefaultsSettingsMutationSource? = nil,
        supersededMutationSource: UserDefaultsSettingsMutationSource? = nil,
        isInitialSnapshot: Bool = false
    ) {
        self.value = value
        self.mutationSource = mutationSource
        self.supersededMutationSource = supersededMutationSource
        self.isInitialSnapshot = isInitialSnapshot
    }
}
