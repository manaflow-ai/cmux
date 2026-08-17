/// The layer that supplied a resolved `DefaultsKey` value.
public enum DefaultsValueSource: String, Sendable, Equatable {
    case user
    case remoteDefault
    case compileDefault
}

/// A resolved `DefaultsKey` value together with its provenance.
public struct DefaultsValueResolution<Value: SettingCodable>: Sendable, Equatable {
    public let value: Value
    public let source: DefaultsValueSource

    public init(value: Value, source: DefaultsValueSource) {
        self.value = value
        self.source = source
    }
}
