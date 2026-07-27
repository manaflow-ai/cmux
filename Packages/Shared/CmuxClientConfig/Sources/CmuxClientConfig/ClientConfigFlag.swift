/// A declared feature flag with a typed value resolver.
public struct ClientConfigFlag<Value: Sendable>: Sendable {
    /// The PostHog feature flag key.
    public let key: String
    /// The value returned when the API omits the flag or the value has the wrong shape.
    public let defaultValue: Value
    /// Converts the raw flag and payload values into the typed value.
    public let resolve: @Sendable (ClientConfigFlagValue?, ClientConfigJSONValue?) -> Value

    /// Creates a typed feature flag declaration.
    public init(
        key: String,
        defaultValue: Value,
        resolve: @escaping @Sendable (ClientConfigFlagValue?, ClientConfigJSONValue?) -> Value
    ) {
        self.key = key
        self.defaultValue = defaultValue
        self.resolve = resolve
    }
}

/// Boolean feature flag declarations.
public extension ClientConfigFlag where Value == Bool {
    /// Creates a boolean flag declaration.
    init(booleanKey key: String, defaultValue: Bool = false) {
        self.init(key: key, defaultValue: defaultValue) { value, _ in
            value?.boolValue ?? defaultValue
        }
    }

    /// Enables Windows download/sign-up surfaces.
    static let cmuxForWindows = Self(booleanKey: "cmux-for-windows")
    /// Enables Linux download/sign-up surfaces.
    static let cmuxForLinux = Self(booleanKey: "cmux-for-linux")
    /// Enables Android download/sign-up surfaces.
    static let cmuxForAndroid = Self(booleanKey: "cmux-for-android")
    /// Enables the production upgrade UI.
    static let proUpgradeUIEnabledRelease = Self(booleanKey: "pro-upgrade-ui-enabled-release")
    /// Enables the production mobile connect button.
    static let mobileConnectButtonEnabledRelease = Self(booleanKey: "mobile-connect-button-enabled-release")
}

/// Multivariate feature flag declarations.
public extension ClientConfigFlag where Value == String? {
    /// Creates a multivariate flag declaration.
    init(variantKey key: String, defaultValue: String? = nil) {
        self.init(key: key, defaultValue: defaultValue) { value, _ in
            value?.variantValue ?? defaultValue
        }
    }
}
