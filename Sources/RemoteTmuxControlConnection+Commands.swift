import Foundation

extension RemoteTmuxControlConnection {
    /// Sends a tmux command on the control stream (newline-terminated).
    @discardableResult
    func send(_ command: String) -> Bool {
        sendInternal(command, kind: .other)
    }

    /// Atomically enqueues a window-reorder batch and its result correlation.
    func sendWindowReorder(
        _ commands: [String],
        verification: ((Bool) -> Void)? = nil
    ) -> Bool {
        guard !commands.isEmpty else {
            verification?(true)
            return true
        }
        guard windowReorderRecoveryGeneration == nil,
              windowReorderVerificationGeneration == nil else { return false }
        let kinds: [CommandKind] = commands.indices.map {
            .windowReorder(isLast: $0 == commands.index(before: commands.endIndex))
        }
        guard sendBatchInternal(commands, kinds: kinds) else { return false }
        windowReorderGeneration &+= 1
        windowReorderVerificationGeneration = windowReorderGeneration
        windowReorderVerifications[windowReorderGeneration] = verification
        return true
    }

    /// Sends `new-window -P -F '#{window_id}'` and returns its stable window id.
    @discardableResult
    func sendNewWindow(_ command: String, completion: @escaping (Int?) -> Void) -> Bool {
        let token = UUID()
        newWindowCompletions[token] = completion
        guard sendInternal(command, kind: .newWindow(token)) else {
            newWindowCompletions.removeValue(forKey: token)?(nil)
            return false
        }
        return true
    }
}
