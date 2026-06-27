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

extension UserDefaultsSettingsValueEvent {
    var deliveryMutationSource: UserDefaultsSettingsMutationSource? {
        mutationSource ?? supersededMutationSource
    }

    func mergingDroppedSource(from droppedEvent: Self) -> Self {
        guard mutationSource == nil,
              supersededMutationSource == nil,
              let droppedSource = droppedEvent.deliveryMutationSource
        else { return self }
        return Self(
            value: value,
            supersededMutationSource: droppedSource,
            isInitialSnapshot: isInitialSnapshot
        )
    }
}

extension AsyncStream.Continuation {
    func yieldPreservingSources<Value: SettingCodable>(
        _ event: UserDefaultsSettingsValueEvent<Value>
    ) where Element == UserDefaultsSettingsValueEvent<Value> {
        var mergedEvent = event
        while true {
            switch yield(mergedEvent) {
            case .dropped(let droppedEvent):
                let nextEvent = mergedEvent.mergingDroppedSource(from: droppedEvent)
                guard nextEvent != mergedEvent else { return }
                mergedEvent = nextEvent
            default:
                return
            }
        }
    }
}
