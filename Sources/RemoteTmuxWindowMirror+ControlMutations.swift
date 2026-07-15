import Foundation

@MainActor
extension RemoteTmuxWindowMirror {
    func sendInput(toPane tmuxPaneID: Int, text: String) -> Bool {
        guard let data = text.data(using: .utf8) else { return false }
        return connectionSendKeys(paneID: tmuxPaneID, data: data)
    }

    func sendKey(toPane tmuxPaneID: Int, name: String) -> RemoteTmuxControlKeySendResult {
        guard let key = Self.tmuxKeyName(name) else { return .unknownKey }
        return sendControlCommand("send-keys -t %\(tmuxPaneID) \(key)") ? .sent : .rejected
    }

    static func tmuxKeyName(_ raw: String) -> String? {
        let normalized = raw.lowercased().replacingOccurrences(of: "+", with: "-")
        let aliases: [String: String] = [
            "enter": "Enter", "return": "Enter", "tab": "Tab",
            "escape": "Escape", "esc": "Escape", "backspace": "BSpace",
            "delete": "DC", "del": "DC", "forward_delete": "DC",
            "up": "Up", "arrow_up": "Up", "arrowup": "Up",
            "down": "Down", "arrow_down": "Down", "arrowdown": "Down",
            "left": "Left", "arrow_left": "Left", "arrowleft": "Left",
            "right": "Right", "arrow_right": "Right", "arrowright": "Right",
            "shift-tab": "BTab", "backtab": "BTab", "home": "Home",
            "end": "End", "pageup": "PPage", "page_up": "PPage",
            "pagedown": "NPage", "page_down": "NPage", "space": "Space",
            "sigint": "C-c", "eof": "C-d", "sigtstp": "C-z", "sigquit": "C-\\",
        ]
        if let alias = aliases[normalized] { return alias }
        let parts = normalized.split(separator: "-").map(String.init)
        guard let base = parts.last, base.utf8.count == 1,
              let byte = base.utf8.first,
              (byte >= 48 && byte <= 57) || (byte >= 97 && byte <= 122) else {
            return nil
        }
        let modifiers = parts.dropLast().compactMap { modifier -> String? in
            switch modifier {
            case "ctrl", "control": return "C"
            case "shift": return "S"
            case "alt", "opt", "option": return "M"
            default: return nil
            }
        }
        guard modifiers.count == parts.count - 1 else { return nil }
        return (modifiers + [base]).joined(separator: "-")
    }

    /// Requests pane selection. The next tmux publication remains authoritative
    /// even after the writer accepts this command. Distinct from the UI's
    /// fire-and-forget `focus(pane:)`.
    @discardableResult
    func controlFocus(pane tmuxPaneID: Int) -> Bool {
        sendControlCommand("select-pane -t @\(windowId).%\(tmuxPaneID)")
    }

    /// Splits the addressed tmux pane. The new pane arrives through the next
    /// authoritative layout publication.
    @discardableResult
    func requestSplit(fromPane tmuxPaneID: Int, vertical: Bool) -> Bool {
        sendControlCommand(
            "split-window \(vertical ? "-v" : "-h") -t @\(windowId).%\(tmuxPaneID)"
        )
    }

    /// Resizes the addressed tmux pane by `amountCells` relative to one of its
    /// borders. Tmux's next layout publication remains the sole source of applied
    /// geometry.
    @discardableResult
    func requestResizePane(_ tmuxPaneID: Int, direction: String, amountCells: Int) -> Bool {
        guard amountCells > 0 else { return false }
        let flag: String
        switch direction {
        case "left": flag = "-L"
        case "right": flag = "-R"
        case "up": flag = "-U"
        case "down": flag = "-D"
        default: return false
        }
        return sendControlCommand(
            "resize-pane -t @\(windowId).%\(tmuxPaneID) \(flag) \(amountCells)"
        )
    }

    /// Sets the addressed tmux pane's width or height in terminal cells. This
    /// is shared by CLI absolute resizing and native divider propagation.
    @discardableResult
    func requestResizePane(_ tmuxPaneID: Int, absoluteAxis: String, targetCells: Int) -> Bool {
        guard targetCells > 0 else { return false }
        let flag: String
        switch absoluteAxis {
        case "horizontal": flag = "-x"
        case "vertical": flag = "-y"
        default: return false
        }
        return sendControlCommand(
            "resize-pane -t @\(windowId).%\(tmuxPaneID) \(flag) \(targetCells)"
        )
    }

    /// Sets the addressed tmux pane's width or height as a percentage of the
    /// tmux window, preserving native `resize-pane -x/-y N%` semantics.
    @discardableResult
    func requestResizePane(_ tmuxPaneID: Int, absoluteAxis: String, targetPercentage: Int) -> Bool {
        guard targetPercentage > 0 else { return false }
        let flag: String
        switch absoluteAxis {
        case "horizontal": flag = "-x"
        case "vertical": flag = "-y"
        default: return false
        }
        return sendControlCommand(
            "resize-pane -t @\(windowId).%\(tmuxPaneID) \(flag) \(targetPercentage)%"
        )
    }

    /// Respawns the addressed tmux pane without replacing its projected IDs.
    @discardableResult
    func requestRespawnPane(
        _ tmuxPaneID: Int,
        command shellCommand: String,
        workingDirectory: String?
    ) -> Bool {
        guard RemoteTmuxHost.controlModeLineSafeName(shellCommand) != nil else {
            return false
        }
        var command = "respawn-pane -k -t @\(windowId).%\(tmuxPaneID)"
        if let directory = workingDirectory {
            guard RemoteTmuxHost.controlModeLineSafeName(directory) != nil else { return false }
            command += " -c \(RemoteTmuxHost.shellSingleQuoted(directory))"
        }
        command += " \(RemoteTmuxHost.shellSingleQuoted(shellCommand))"
        return sendControlCommand(command)
    }

    /// Kills the addressed tmux pane. Removal arrives through the next layout
    /// publication (or window-close event for the last pane).
    @discardableResult
    func requestKillPane(_ tmuxPaneID: Int) -> Bool {
        sendControlCommand("kill-pane -t @\(windowId).%\(tmuxPaneID)")
    }
}
