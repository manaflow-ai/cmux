/// Host mode: the DevTools opens and closes cmux sent the Chromium Host that it has not answered yet,
/// in wire order, for one inspected browser (task 033 of plans/cmux-next/chrome-parity/p01-process.md).
///
/// cmux sends an open only while it expects DevTools closed and a close only while it expects it open,
/// so each change in flight gets exactly one answer (OPENED or CLOSED) and the host answers them in
/// the order they went. The toggle decides from the state the host reaches after every change in
/// flight, as Chrome's toggle decides from browser-process state in the key's turn
/// (chrome/browser/devtools/devtools_window.cc, `DevToolsWindow::ToggleDevToolsWindow`).
nonisolated struct CEFHostedDevToolsRequests: Equatable, Sendable {
    nonisolated enum Change: Equatable, Sendable {
        /// An open, with the command to run again if it opens unplaced (the last one cmux sent for it).
        case open(BrowserDevToolsCommand)
        case close
    }

    /// The inspected browser the changes went to; a new browser of the tab starts with none in flight.
    private(set) var browser: Int32?
    private(set) var changes: [Change] = []

    /// Whether DevTools is open once the host answered every change in flight to `browser`; nil when
    /// none is in flight.
    func expectsOpen(browser: Int32) -> Bool? {
        guard browser == self.browser, let last = changes.last else { return nil }
        return last != .close
    }

    /// cmux sent `change` to `browser`.
    mutating func sent(_ change: Change, browser: Int32) {
        if browser != self.browser { (self.browser, changes) = (browser, []) }
        changes.append(change)
    }

    /// Another opening command went while the last change in flight is an open: it becomes the
    /// command that open runs again, as the latest command keeps its target.
    mutating func retarget(_ command: BrowserDevToolsCommand, browser: Int32) {
        guard browser == self.browser, case .open = changes.last else { return }
        changes[changes.count - 1] = .open(command)
    }

    /// The host's OPENED for `browser`: takes the open it answers. Returns that open's command (nil
    /// when cmux sent none: Chromium's own open) and whether a close for it is already on the wire.
    mutating func opened(browser: Int32) -> (command: BrowserDevToolsCommand?, closing: Bool) {
        guard browser == self.browser else { return (nil, false) }
        var command: BrowserDevToolsCommand?
        if case .open(let sent) = changes.first {
            command = sent
            changes.removeFirst()
        }
        return (command, changes.first == .close)
    }

    /// Whether the open the host is answering now (its WILL_OPEN came) closes again once it opened.
    func closesAfterOpening(browser: Int32) -> Bool {
        guard browser == self.browser, case .open = changes.first else { return false }
        return changes.dropFirst().first == .close
    }

    /// The host's CLOSED for `browser`: takes the close it answers.
    mutating func closed(browser: Int32) {
        guard browser == self.browser, changes.first == .close else { return }
        changes.removeFirst()
    }
}
