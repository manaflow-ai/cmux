import Foundation

extension RefusalStrings {
    /// Run Last Command Again found no finished command the daemon kept for the terminal.
    public static var noLastCommand: String {
        text("handlers.misc.failed.noLastCommand", "This terminal has no finished command to run again.")
    }

    /// Run Last Command Again found another program in front of the shell.
    public static var programRunning: String {
        text("handlers.misc.failed.programRunning", "A program is running in this terminal.")
    }
}
