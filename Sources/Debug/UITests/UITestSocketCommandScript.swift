#if DEBUG
import Foundation

/// Seeds app state for a UI test by running control-socket commands inside
/// the app, so a test can set up sidebar statuses, git branches, pull
/// requests and so on without per-test Swift hooks. XCUITest runners cannot
/// reliably connect to the app's Unix socket on CI, so the app runs them
/// itself through the same dispatcher (`TerminalController.handleSocketLine`).
///
/// - `CMUX_UI_TEST_SOCKET_COMMANDS`: newline-separated commands, run in
///   order. `{last}` is replaced by the id the most recent `new_*` command
///   returned (`new_workspace`, `new_split`, ...). `wait <ms>` pauses without
///   sending anything, e.g. to let a new workspace's terminal panel appear
///   before per-panel reports (`set_agent_lifecycle`, `report_git_branch`).
///   `let <name>` saves the current `{last}` as `{<name>}`, to address that
///   workspace after others were created. `{surface}` is the surface id the
///   most recent `list_surfaces` returned (for `notify_target`). A line
///   starting with `{"` is a v2 JSON request; `{group}` is the group id the
///   most recent `workspace.group.create` returned, and an `"ok": false`
///   reply counts as a failure. `{pid}` is the app's own process id, a live
///   PID for `set_agent_pid` (agent status rows show only for a live agent).
/// - `CMUX_UI_TEST_SOCKET_COMMANDS_RESULT_PATH`: JSON written when done:
///   `{"done": "1", "replies": [...], "failed": "0|1"}`; wait on it before
///   asserting on the UI.
struct UITestSocketCommandScript: Equatable {
    static let commandsKey = "CMUX_UI_TEST_SOCKET_COMMANDS"
    static let resultPathKey = "CMUX_UI_TEST_SOCKET_COMMANDS_RESULT_PATH"

    let commands: [String]

    init?(environment: [String: String]) {
        guard let raw = environment[Self.commandsKey] else { return nil }
        let commands = raw
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !commands.isEmpty else { return nil }
        self.commands = commands
    }

    /// Runs every command through `handle`, substituting `{last}`, and
    /// returns the replies in order.
    func run(
        processIdentifier: Int32 = ProcessInfo.processInfo.processIdentifier,
        _ handle: (String) -> String,
        sleep: (Int) -> Void = { usleep(useconds_t(max(0, $0)) * 1000) }
    ) -> [String] {
        var values: [String: String] = ["pid": String(processIdentifier)]
        var replies: [String] = []
        for command in commands {
            if let milliseconds = Self.waitMilliseconds(command) {
                sleep(milliseconds)
                replies.append("OK")
                continue
            }
            if let name = Self.letName(command) {
                values[name] = values["last"]
                replies.append(values["last"] == nil ? "ERROR: no {last} to save" : "OK")
                continue
            }
            let line = Self.substitute(command, values: values)
            let reply = handle(line)
            replies.append(reply)
            if line.hasPrefix("new_"), let id = Self.lastUUID(in: reply) {
                values["last"] = id
            }
            if line.hasPrefix("list_surfaces"), let id = Self.lastUUID(in: reply) {
                values["surface"] = id
            }
            if let id = Self.createdGroupId(in: reply) {
                values["group"] = id
            }
        }
        return replies
    }

    static func waitMilliseconds(_ command: String) -> Int? {
        let parts = command.split(separator: " ")
        guard parts.count == 2, parts[0] == "wait", let value = Int(parts[1]), value >= 0 else { return nil }
        return min(value, 10_000)
    }

    static func letName(_ command: String) -> String? {
        let parts = command.split(separator: " ")
        guard parts.count == 2, parts[0] == "let", !parts[1].contains("{") else { return nil }
        return String(parts[1])
    }

    static func substitute(_ command: String, values: [String: String]) -> String {
        values.reduce(command) { line, value in
            line.replacingOccurrences(of: "{\(value.key)}", with: value.value)
        }
    }

    /// `result.group.id` of a v2 `workspace.group.create` reply.
    static func createdGroupId(in reply: String) -> String? {
        let result = v2Reply(reply)?["result"] as? [String: Any]
        return (result?["group"] as? [String: Any])?["id"] as? String
    }

    static func isFailure(_ reply: String) -> Bool {
        reply.isEmpty || reply.hasPrefix("ERROR") || v2Reply(reply)?["ok"] as? Bool == false
    }

    private static func v2Reply(_ reply: String) -> [String: Any]? {
        guard reply.hasPrefix("{"), let data = reply.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    static func lastUUID(in reply: String) -> String? {
        reply.split(whereSeparator: { $0.isWhitespace || $0 == "," || $0 == "\"" })
            .reversed()
            .first { UUID(uuidString: String($0)) != nil }
            .map(String.init)
    }

    /// Starts the script once the app has finished launching, off the main
    /// actor (socket commands hop to it themselves), and writes the result file.
    static func runIfRequested(
        environment: [String: String],
        handle: @escaping @Sendable (String) -> String
    ) {
        guard let script = UITestSocketCommandScript(environment: environment) else { return }
        let resultPath = environment[resultPathKey]
        Task.detached(priority: .userInitiated) {
            try? await Task.sleep(for: .milliseconds(500))
            let replies = script.run(handle)
            guard let resultPath, !resultPath.isEmpty else { return }
            let failed = replies.contains(where: Self.isFailure)
            let payload: [String: Any] = ["done": "1", "failed": failed ? "1" : "0", "replies": replies]
            if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]) {
                try? data.write(to: URL(fileURLWithPath: resultPath), options: .atomic)
            }
        }
    }
}
#endif
