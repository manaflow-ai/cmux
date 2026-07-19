struct CmuxFeatureFlagResolution: Equatable, Sendable {
    enum Source: Equatable, Sendable {
        case remote
        case override
        case `default`
    }

    let effectiveValue: Bool
    let source: Source

    init(remoteValue: Bool?, overrideValue: Bool?, defaultValue: Bool) {
        if let remoteValue {
            effectiveValue = remoteValue
            source = .remote
        } else if let overrideValue {
            effectiveValue = overrideValue
            source = .override
        } else {
            effectiveValue = defaultValue
            source = .default
        }
    }
}
