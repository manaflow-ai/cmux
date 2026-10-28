/// Which builds may send opt-in hang reports (plans/cmux-next/hang-reports-DESIGN.md): NIGHTLY, and DEV only with its
/// end-to-end opt-in; never Release or RC, and never a test process (``isTestProcess(_:)``).
extension CrashReportingPolicy {
    /// The channel of the bundle `bundleID` (nil for a build that does not identify as cmux), with no other read.
    public static func channel(bundleID: String?, isDebugBuild: Bool) -> Channel? {
        identity(bundleID: bundleID, isDebugBuild: isDebugBuild)?.channel
    }

    /// Whether a build of `channel` may send hang reports; `devOptIn`: a DEV build's opt-in is set.
    public static func mayReportHangs(channel: Channel?, devOptIn: Bool, environment: [String: String]) -> Bool {
        (channel == .nightly || (channel == .dev && devOptIn)) && !isTestProcess(environment)
    }
}
