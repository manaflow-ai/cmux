struct CmuxFeatureFlagResolution: Equatable, Sendable {
    let effectiveValue: Bool
    let source: CmuxFeatureFlagSource

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
