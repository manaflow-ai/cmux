internal import CCmuxDaemonLaunchFFI
import CmuxNextDaemon
import Foundation

/// Calls the same Rust cache resolver as the CLI. The caller owns the file-I/O lane.
struct CloudLaunchCache {
    func read(bundleID: String, home: String, arguments: [String], environment: [String: String]) throws -> CloudRuntimeSelection? {
        let request = try JSONSerialization.data(withJSONObject: [
            "bundleId": bundleID, "home": home, "arguments": arguments, "environment": environment,
        ])
        var output = CmuxDaemonLaunchBytes(ptr: nil, len: 0)
        defer { cmux_daemon_launch_bytes_free(output) }
        let code = "cloud_environment_local".withCString { operation in
            request.withUnsafeBytes { bytes in
                cmux_daemon_launch_call(operation, bytes.baseAddress?.assumingMemoryBound(to: UInt8.self), bytes.count, &output)
            }
        }
        // An older library keeps the existing CLI path until the additive FFI release is pinned.
        guard code == CMUX_DAEMON_LAUNCH_OK, let pointer = output.ptr else { return nil }
        let data = Data(bytes: pointer, count: output.len)
        guard let reply = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DaemonError.launchFailed("Invalid local Cloud environment response.")
        }
        if let error = reply["error"] as? String {
            throw DaemonError.launchFailed("Could not resolve this app's Cloud environment: " + error)
        }
        if reply["needsFetch"] as? Bool == true { return nil }
        guard let selection = reply["selection"] as? [String: Any] else {
            throw DaemonError.launchFailed("The local Cloud environment response has no selection.")
        }
        return try CloudRuntimeSelection.decode(JSONSerialization.data(withJSONObject: selection))
    }
}
