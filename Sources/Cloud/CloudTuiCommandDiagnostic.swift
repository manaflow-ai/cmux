import Foundation
import os

/// Records command identity without argv, terminal bytes, paths or daemon prose.
/// A resource-command exit is distinct from the machine link process exiting.
struct CloudTuiCommandDiagnostic {
    let operation: String
    let selector: String
    let code: String
    let scope: String

    init(arguments: [String], output: String) {
        // App commands begin with an explicit socket and JSON output mode.
        let words = Array(arguments.dropFirst(3))
        let resourceScopes = ["session", "workspace", "screen", "pane", "tab", "terminal"]
        let verbs = ["snapshot", "events", "run", "split", "move", "close", "rename", "project", "write", "keys"]
        if words.count >= 3, resourceScopes.contains(words[0]), verbs.contains(words[2]) {
            operation = words[0] + "." + words[2]
            selector = words[1]
        } else {
            operation = "other"
            selector = ""
        }
        let knownCodes = ["selector.not_found", "selector.wrong_parent", "selector.invalid", "revision.conflict", "transport.timeout", "transport.closed"]
        let object = output.split(whereSeparator: \.isNewline).lazy.compactMap {
            try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
        }.first
        let rawCode = object?["code"] as? String ?? ""
        code = knownCodes.contains(rawCode) ? rawCode : "other"
        let rawScope = (object?["details"] as? [String: Any])?["scope"] as? String ?? ""
        scope = resourceScopes.contains(rawScope) ? rawScope : "other"
    }

    func record(machineID: String, status: Int32) {
        Logger(subsystem: "com.cmuxterm.app", category: "CloudTerminalLifecycle").error(
            "command.failed machine=\(machineID, privacy: .private(mask: .hash)) operation=\(operation, privacy: .public) selector=\(selector, privacy: .private(mask: .hash)) status=\(status) code=\(code, privacy: .public) scope=\(scope, privacy: .public)"
        )
    }
}
