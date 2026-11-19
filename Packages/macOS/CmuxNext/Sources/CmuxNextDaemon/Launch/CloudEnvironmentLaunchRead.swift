public import Foundation

/// The launch's Cloud environment read in this process (cmux-daemon-launch-core's
/// `cloud_environment_launch_read`): what the bundled CLI's `cloud env get --cache-first --launch-args`
/// answered, with no child process and no network read. Rust seeds, resolves and persists it; this only
/// carries the request and the answer.
public enum CloudEnvironmentLaunchRead {
    /// The selection as the CLI's `--json` answer (snake_case), or nil when only the CLI can answer:
    /// a fetch is needed (a custom origin with no cache), the read failed (the CLI says why), or this
    /// app's Rust library has no such op yet.
    public static func selectionJSON(bundleID: String, home: String, arguments: [String],
                                     environment: [String: String]) -> Data? {
        let reply = DaemonLaunchRules.call("cloud_environment_launch_read", [
            "bundleId": bundleID, "home": home, "arguments": arguments,
            "environment": environment.filter { $0.key == "CMUX_NEXT_CLOUD_BACKEND" || $0.key == "CMUX_NEXT_CLOUD_ENV" },
        ])
        guard let selection = (reply as? [String: Any])?["selection"] as? [String: Any] else { return nil }
        return try? JSONSerialization.data(withJSONObject: selection)
    }
}
