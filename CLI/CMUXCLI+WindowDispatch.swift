import Foundation

// Shared pre-dispatch focus policy. Read-only commands must never gain a
// mutation merely because the caller supplies the global --window option.
extension CMUXCLI {
    static func shouldFocusWindowBeforeDispatch(command: String, commandArgs: [String]) -> Bool {
        let normalizedCommand = command.lowercased()
        // `window` repositions a window (e.g. `window display`); it must not
        // pre-focus, or it would steal macOS focus before moving the window.
        if normalizedCommand == "window" {
            return false
        }
        if normalizedCommand == "surface-resume" {
            return false
        }
        if normalizedCommand == "restore" || normalizedCommand == "fork" {
            return false
        }
        if normalizedCommand == "local-tmux" || normalizedCommand == "tmux" {
            // The local-tmux command owns its explicit --focus decision; do
            // not activate a window as a side effect of global --window parsing.
            return false
        }
        if normalizedCommand == "read-screen" || normalizedCommand == "read-selection" || normalizedCommand == "current" {
            return false
        }
        if normalizedCommand == "rpc",
           commandArgs.first?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                == "surface.read_selection" {
            return false
        }
        if normalizedCommand == "surface", commandArgs.first?.lowercased() == "resume" {
            return false
        }
        if Self.commandDefersSocketConnectionUntilRequest(command: command, commandArgs: commandArgs) {
            return false
        }
        return true
    }

}
