import CmuxNextCompat
public import Foundation
import CmuxNextWakeups

/// The check after an update (cmux-tui `cmux app health`, cli/app/health.rs): the running
/// bundle's own CLI asks this app's socket whether chat, the model picker, the chat relay and a
/// terminal work, and answers one JSON report. The checks live in Rust; this only runs the CLI
/// off the main actor and reads its report.
nonisolated public struct UpdateHealthCheck: Sendable {
    /// One check of the report (`checks[]`).
    public struct Check: Equatable, Sendable {
        public var name: String
        public var ok: Bool
        public var reason: String
        public var detail: String
    }

    /// The report: every check, and the running build's commit as its stamps name it.
    public struct Report: Equatable, Sendable {
        public var ok: Bool
        public var commit: String?
        public var checks: [Check]
        public var failed: [Check] { checks.filter { !$0.ok && $0.reason != "skipped" } }
    }

    /// The bundle whose CLI runs (the running app's).
    public let bundle: URL
    /// The CLI's own deadlines add up to under two minutes; this bounds a hung CLI.
    public var timeout: Duration = .seconds(150)

    public init(bundle: URL) {
        self.bundle = bundle
    }

    /// Runs `cmux --app-socket socket app health --since-ms since --open-chat --json`. Nil when
    /// it says nothing to judge by (no app answered, it timed out, or it predates the check).
    @concurrent public func run(socket: String, since: Date) async -> Report? {
        let cli = bundle.appending(path: "Contents/Resources/bin/cmux")
        let arguments = ["--app-socket", socket, "app", "health",
                         "--since-ms", String(Int64(since.timeIntervalSince1970 * 1000)), "--open-chat", "--json"]
        // Outside any terminal's targeting: this app's socket only, never an inherited one.
        var environment = ProcessInfo.processInfo.environment
        for key in ["CMUX_SOCKET_PATH", "CMUX_BUNDLE_ID", "CMUX_TAG", "ACPMUX_SOCKET"] { environment[key] = nil }
        let request = ProcessRequest(cli, arguments, environment: environment, timeout: timeout)
        guard let outcome = try? await AsyncProcess().run(request), outcome.exited else { return nil }
        // 0: every check passed; 1: one failed (the report says which); else nothing to judge.
        guard outcome.status == 0 || outcome.status == 1 else { return nil }
        return Self.parse(outcome.output)
    }

    static func parse(_ data: Data) -> Report? {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let ok = object["ok"] as? Bool, let rows = object["checks"] as? [[String: Any]] else { return nil }
        let checks = rows.compactMap { row -> Check? in
            guard let name = row["name"] as? String, let passed = row["ok"] as? Bool else { return nil }
            return Check(name: name, ok: passed, reason: row["reason"] as? String ?? "",
                         detail: row["detail"] as? String ?? "")
        }
        let commit = (object["app"] as? [String: Any])?["commit"] as? String
        return Report(ok: ok, commit: commit, checks: checks)
    }

    /// The commit a bundle's cmux-tui stamp names (`Contents/Resources/bin/cmux-tui.version`,
    /// one `key=value` per line), or nil.
    public static func commit(of bundle: URL) -> String? {
        let stamp = bundle.appending(path: "Contents/Resources/bin/cmux-tui.version")
        guard let data = try? Data(blockingContentsOf: stamp) else { return nil }
        return String(decoding: data, as: UTF8.self).split(separator: "\n").lazy.compactMap { line -> String? in
            let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            return parts.count == 2 && parts[0] == "commit" && !parts[1].isEmpty ? parts[1] : nil
        }.first
    }
}
