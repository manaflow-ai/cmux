import Foundation

extension RemoteTmuxControlConnection {
    /// Sends a tmux command on the control stream (newline-terminated).
    @discardableResult
    func send(_ command: String) -> Bool {
        sendInternal(command, kind: .other)
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
