import Foundation

extension CloudTuiCommandLine {
    /// `tab <tab_id> move --workspace <ws> --screen <screen> --pane <pane> --index <n>`
    /// (spec `tab.move`, the destination grammar `terminal … project` uses): re-parents
    /// one placement; the terminal or browser behind it is untouched.
    static func moveTabArguments(
        socketPath: String,
        tabID: String,
        target: CloudTuiTerminalProjectionTarget,
        expectedRevision: String? = nil,
        idempotencyKey: String? = nil
    ) -> [String] {
        var arguments = [
            "--socket", socketPath, "--json", "tab", tabID, "move",
            "--workspace", target.workspaceID,
            "--screen", target.screenID,
            "--pane", target.paneID,
            "--index", String(target.index),
        ]
        if let expectedRevision, !expectedRevision.isEmpty {
            arguments += ["--expected-revision", expectedRevision]
        }
        if let idempotencyKey, !idempotencyKey.isEmpty {
            arguments += ["--idempotency-key", idempotencyKey]
        }
        return arguments
    }
}
