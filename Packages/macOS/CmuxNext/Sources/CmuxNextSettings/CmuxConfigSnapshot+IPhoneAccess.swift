extension CmuxConfigSnapshot {
    /// `browser.allowIPhoneAccess` in cmux.json: Chromium opens its DevTools
    /// protocol on a random loopback port so cmux on iPhone can view and
    /// control this Mac's Chromium tabs. Off by default; read when Chromium
    /// starts, so a change takes effect after cmux restarts.
    public static let browserAllowIPhoneAccessPath = ["browser", "allowIPhoneAccess"]

    /// `browser.allowIPhoneAccess`; off when unset or not a bool (the schema
    /// reports a value of the wrong type).
    public var browserAllowsIPhoneAccess: Bool {
        root.value(at: Self.browserAllowIPhoneAccessPath)?.boolValue ?? false
    }
}
