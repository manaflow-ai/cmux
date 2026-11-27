/// One observed `UserDefaults` setting value plus its optional mutation source.
public struct UserDefaultsSettingsValueEvent<Value: SettingCodable>: Sendable, Equatable {
    /// The decoded value for the observed key.
    public let value: Value

    /// One-shot source attached to this observed store-owned write, if any.
    public let mutationSource: UserDefaultsSettingsMutationSource?

    /// Sources whose stored values were overwritten before observation emitted them.
    public let supersededMutationSources: [UserDefaultsSettingsMutationSource]

    /// The newest source whose stored value was overwritten before observation emitted it.
    public var supersededMutationSource: UserDefaultsSettingsMutationSource? {
        supersededMutationSources.last
    }

    /// Whether this event is the stream's initial store snapshot.
    public let isInitialSnapshot: Bool

    /// Creates an observed value event.
    public init(
        value: Value,
        mutationSource: UserDefaultsSettingsMutationSource? = nil,
        supersededMutationSource: UserDefaultsSettingsMutationSource? = nil,
        supersededMutationSources: [UserDefaultsSettingsMutationSource] = [],
        isInitialSnapshot: Bool = false
    ) {
        self.value = value
        self.mutationSource = mutationSource
        var sources = supersededMutationSources
        if let supersededMutationSource, !sources.contains(supersededMutationSource) {
            sources.append(supersededMutationSource)
        }
        self.supersededMutationSources = sources
        self.isInitialSnapshot = isInitialSnapshot
    }
}

extension UserDefaultsSettingsValueEvent {
    var deliveryMutationSource: UserDefaultsSettingsMutationSource? {
        mutationSource ?? supersededMutationSource
    }

    var deliveryMutationSources: [UserDefaultsSettingsMutationSource] {
        var sources = supersededMutationSources
        if let mutationSource, !sources.contains(mutationSource) {
            sources.append(mutationSource)
        }
        return sources
    }

    func mergingDroppedSource(from droppedEvent: Self) -> Self {
        let droppedSources = droppedEvent.deliveryMutationSources
        guard !droppedSources.isEmpty else { return self }
        var mergedSupersededSources = supersededMutationSources
        for droppedSource in droppedSources
        where droppedSource != mutationSource && !mergedSupersededSources.contains(droppedSource) {
            mergedSupersededSources.append(droppedSource)
        }
        guard mergedSupersededSources != supersededMutationSources else { return self }
        return Self(
            value: value,
            mutationSource: mutationSource,
            supersededMutationSources: mergedSupersededSources,
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
