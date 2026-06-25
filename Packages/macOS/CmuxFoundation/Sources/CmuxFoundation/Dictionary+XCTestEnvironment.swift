extension [String: String] {
    /// Whether this process-environment snapshot indicates an XCTest (or cmux
    /// UI-test) host.
    ///
    /// The broad superset the app uses to decide whether to skip heavyweight
    /// startup work and bring up a window: on some macOS/Xcode setups the
    /// app-under-test process never receives `XCTestConfigurationFilePath`, so
    /// the presence of any related signal counts. A pure predicate on the
    /// receiver, with no AppKit, `ProcessInfo`, or live state.
    ///
    /// Returns `true` when ANY of the following holds, matching the legacy
    /// `AppDelegate` superset semantics byte-for-byte:
    /// - Presence of `XCTestConfigurationFilePath`, `XCTestBundlePath`,
    ///   `XCTestSessionIdentifier`, `XCInjectBundle`, or `XCInjectBundleInto`
    ///   (presence of the key counts, even when its value is empty).
    /// - `DYLD_INSERT_LIBRARIES` containing the substring `libXCTest`.
    /// - Any key with the prefix `CMUX_UI_TEST_`.
    public var indicatesXCTestHost: Bool {
        if self["XCTestConfigurationFilePath"] != nil { return true }
        if self["XCTestBundlePath"] != nil { return true }
        if self["XCTestSessionIdentifier"] != nil { return true }
        if self["XCInjectBundle"] != nil { return true }
        if self["XCInjectBundleInto"] != nil { return true }
        if self["DYLD_INSERT_LIBRARIES"]?.contains("libXCTest") == true { return true }
        if keys.contains(where: { $0.hasPrefix("CMUX_UI_TEST_") }) { return true }
        return false
    }
}
