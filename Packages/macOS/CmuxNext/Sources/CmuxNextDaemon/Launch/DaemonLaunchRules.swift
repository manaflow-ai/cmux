import CCmuxDaemonLaunchFFI
import Foundation

/// The daemon launch rules, asked of Rust (cmux-tui/crates/cmux-daemon-launch-core, its golden vectors in
/// `tests/cases/*.json`) over the app FFI (module `CCmuxDaemonLaunchFFI`): one JSON op of
/// `cmux_daemon_launch_call` per rule, plus the watch and stderr-lines handles and the login capture's reader.
/// The app reads the facts (its environment, a child's output, the files) and acts on the answer; the rules stay
/// in Rust (Leo, 2026-11-06: "ok we need to go all hands on deck here. don't just do baby steps").
///
/// Every call answers nil only when the library does not (a request the op does not take): each caller then
/// takes its own safe fallback, named where it calls.
enum DaemonLaunchRules {
    /// One op on `request`'s JSON; the reply's JSON, or nil when the op did not answer.
    static func callData(_ op: String, _ request: Data) -> Data? {
        var out = CmuxDaemonLaunchBytes(ptr: nil, len: 0)
        let code = request.withUnsafeBytes { raw in
            op.withCString { cmux_daemon_launch_call($0, raw.bindMemory(to: UInt8.self).baseAddress, raw.count, &out) }
        }
        return take(code, out)
    }

    /// One op: `request` encoded, the reply decoded as `Reply` (an optional `Reply` reads a `null` reply).
    static func call<Reply: Decodable>(_ op: String, _ request: some Encodable, as _: Reply.Type = Reply.self) -> Reply? {
        guard let data = try? JSONEncoder().encode(request), let reply = callData(op, data) else { return nil }
        return try? JSONDecoder().decode(Reply.self, from: reply)
    }

    /// The bytes of a reply buffer, which is freed here.
    static func take(_ code: Int32, _ out: CmuxDaemonLaunchBytes) -> Data? {
        defer { cmux_daemon_launch_bytes_free(out) }
        guard code == CMUX_DAEMON_LAUNCH_OK, let pointer = out.ptr, out.len > 0 else { return nil }
        return Data(bytes: pointer, count: out.len)
    }

    /// The login shell's capture (`status`, raw stdout) as the environment the app keeps; nil when it keeps
    /// none (the shell failed, no marker, no `PATH`).
    static func acceptLoginCapture(status: Int32, output: Data) -> [String: String]? {
        var out = CmuxDaemonLaunchBytes(ptr: nil, len: 0)
        let code = output.withUnsafeBytes { raw in
            cmux_daemon_launch_login_env_accept(status, raw.bindMemory(to: UInt8.self).baseAddress, raw.count, &out)
        }
        guard let reply = take(code, out) else { return nil }
        return (try? JSONDecoder().decode([String: String]?.self, from: reply)) ?? nil
    }

    /// `duration` in whole milliseconds, as the rules count time (negative: 0).
    static func milliseconds(_ duration: Duration) -> UInt64 {
        let (seconds, attoseconds) = duration.components
        guard seconds >= 0 else { return 0 }
        return UInt64(clamping: seconds).multipliedReportingOverflow(by: 1000).partialValue
            &+ UInt64(clamping: attoseconds / 1_000_000_000_000_000)
    }

    /// An environment as a request field.
    struct Environment: Encodable {
        var environment: [String: String]
    }

    /// A text as a request field.
    struct Text: Encodable {
        var text: String
    }
}

/// A child's stderr cut into lines by the Rust splitter (`cmux_daemon_launch_lines_*`). One thread at a time
/// (the caller's lock or queue).
final class DaemonLaunchLineSplitter {
    private let handle: OpaquePointer?

    init() { handle = cmux_daemon_launch_lines_new() }

    deinit { cmux_daemon_launch_lines_free(handle) }

    /// The lines `bytes` complete; `finish` (the child exited) also the last one with no newline, and none after.
    func push(_ bytes: UnsafeRawBufferPointer, finish: Bool) -> [String] {
        guard let handle else { return [] }
        var out = CmuxDaemonLaunchBytes(ptr: nil, len: 0)
        let code = cmux_daemon_launch_lines_push(handle, bytes.bindMemory(to: UInt8.self).baseAddress, bytes.count, finish, &out)
        guard let reply = DaemonLaunchRules.take(code, out) else { return [] }
        return (try? JSONDecoder().decode([String].self, from: reply)) ?? []
    }
}

/// One unresponsive-owner watch's state machine in Rust (`cmux_daemon_launch_watch_*`). One thread at a time
/// (``UnresponsiveOwnerWatch`` calls it under its lock).
final class DaemonLaunchWatchMachine {
    private let handle: OpaquePointer?

    /// - Parameter policy: the policy's JSON (`sustainedMs`, `stuckEnsures`, `perLaunch`).
    init(policy: Data) {
        handle = policy.withUnsafeBytes { raw in
            cmux_daemon_launch_watch_new(raw.bindMemory(to: UInt8.self).baseAddress, raw.count)
        }
    }

    deinit { cmux_daemon_launch_watch_free(handle) }

    /// One watch op; nil when the machine did not answer.
    func call<Reply: Decodable>(_ op: String, _ request: some Encodable, as _: Reply.Type = Reply.self) -> Reply? {
        guard let handle, let data = try? JSONEncoder().encode(request) else { return nil }
        var out = CmuxDaemonLaunchBytes(ptr: nil, len: 0)
        let code = data.withUnsafeBytes { raw in
            op.withCString { cmux_daemon_launch_watch_call(handle, $0, raw.bindMemory(to: UInt8.self).baseAddress, raw.count, &out) }
        }
        guard let reply = DaemonLaunchRules.take(code, out) else { return nil }
        return try? JSONDecoder().decode(Reply.self, from: reply)
    }
}
