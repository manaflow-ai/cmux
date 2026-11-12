internal import CCmuxDaemonLaunchFFI
import Foundation

/// The JSON ops of the app's launch rules in Rust (cmux-tui/crates/cmux-daemon-launch-core,
/// `cmux_daemon_launch.h`, src/ops.rs; tests/cases/*.json list them). A reply is the op's JSON value
/// (`NSNull` for a JSON null), or nil when the op refused the request.
enum DaemonLaunchRules {
    /// One op (`cmux_daemon_launch_call`) on a JSON object.
    static func call(_ op: String, _ request: [String: Any] = [:]) -> Any? {
        guard let json = try? JSONSerialization.data(withJSONObject: request) else { return nil }
        return reply { out in
            json.withUnsafeBytes { bytes in
                cmux_daemon_launch_call(op, bytes.baseAddress?.assumingMemoryBound(to: UInt8.self), bytes.count, out)
            }
        }
    }

    /// The login shell's capture (`status` and its raw stdout): its environment, or nil when it is not
    /// one the app keeps (a failed status, no marker, no entry or no `PATH`;
    /// `cmux_daemon_launch_login_env_accept`).
    static func acceptLoginEnvironment(status: Int32, output: Data) -> [String: String]? {
        let environment = reply { out in
            output.withUnsafeBytes { bytes in
                cmux_daemon_launch_login_env_accept(status, bytes.baseAddress?.assumingMemoryBound(to: UInt8.self),
                                                    bytes.count, out)
            }
        }
        return environment as? [String: String]
    }

    private static func reply(_ body: (UnsafeMutablePointer<CmuxDaemonLaunchBytes>) -> Int32) -> Any? {
        var out = CmuxDaemonLaunchBytes(ptr: nil, len: 0)
        let code = body(&out)
        defer { cmux_daemon_launch_bytes_free(out) }
        guard code == CMUX_DAEMON_LAUNCH_OK, let pointer = out.ptr else { return nil }
        return try? JSONSerialization.jsonObject(with: Data(bytes: pointer, count: out.len), options: .fragmentsAllowed)
    }
}
