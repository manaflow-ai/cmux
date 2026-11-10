internal import CCmuxLayoutReducerFFI
public import CmuxNextDaemon
import Foundation

/// The local terminal commands that keep the Mac awake (`sessions.keepAwakeForCommands`): this
/// Mac's terminal tabs whose shell runs a command, sent to the Rust rule (`keep_awake_plan`,
/// cmux-layout-reducer `keep_awake`), which says how many count and when to look again. Times are
/// on this Mac's clock: a daemon that runs ahead counts from when this client saw the fact.
nonisolated struct KeepAwakeCommands: Equatable, Sendable {
    struct Command: Encodable, Equatable, Sendable {
        var sinceMs: UInt64
        var outputMs: UInt64?
        var agent: Bool
        var terminal: Bool

        enum CodingKeys: String, CodingKey {
            case sinceMs = "since_ms", outputMs = "output_ms", agent, terminal
        }
    }

    /// What `keep_awake_plan` answers.
    struct Plan: Decodable, Equatable, Sendable {
        var running = 0
        var quiet: [Int] = []
        var recheckMs: UInt64?

        enum CodingKeys: String, CodingKey {
            case running, quiet, recheckMs = "recheck_ms"
        }
    }

    var commands: [Command] = []

    /// The running commands of `tabs` (one workspace's: ``KeepAwakeService`` observes each workspace on its own).
    /// Reads only the command and output facts of a tab whose shell runs one, so an observer wakes for those alone.
    @MainActor static func of(_ tabs: [TabModel]) -> Self {
        var out = Self()
        for tab in tabs {
            guard var since = tab.commandSinceMs else { continue }
            if let seen = tab.commandSeenAt { since = min(since, Self.ms(seen)) }
            var output = tab.lastOutputMs
            if let at = output, let seen = tab.lastOutputSeenAt { output = min(at, Self.ms(seen)) }
            out.commands.append(Command(sinceMs: since, outputMs: output,
                                        agent: tab.agent != nil || tab.agentSession != nil, terminal: tab.kind == .pty))
        }
        return out
    }

    /// The Rust rule's answer at `now`; nothing counts when the call fails.
    func plan(now: Date = Date()) -> Plan {
        guard !commands.isEmpty else { return Plan() }
        struct Request: Encodable {
            var nowMs: UInt64
            var commands: [Command]
            enum CodingKeys: String, CodingKey { case nowMs = "now_ms", commands }
        }
        guard let data = try? JSONEncoder().encode(Request(nowMs: Self.ms(now), commands: commands)) else {
            return Plan()
        }
        // One count and two short lists per command: 64 bytes each is ample.
        var output = [UInt8](repeating: 0, count: 256 + commands.count * 64)
        var length = 0
        let code: Int32 = data.withUnsafeBytes { request in
            "keep_awake_plan".withCString { operation in
                output.withUnsafeMutableBytes { buffer in
                    cmux_layout_reducer_json(request.bindMemory(to: UInt8.self).baseAddress, data.count, operation,
                                             buffer.bindMemory(to: UInt8.self).baseAddress, buffer.count, &length)
                }
            }
        }
        guard code == CMUX_LAYOUT_REDUCER_OK, length <= output.count,
              let plan = try? JSONDecoder().decode(Plan.self, from: Data(output.prefix(length))) else {
            return Plan()
        }
        return plan
    }

    static func ms(_ date: Date) -> UInt64 {
        UInt64(max(0, date.timeIntervalSince1970 * 1000))
    }
}
