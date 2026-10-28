import Foundation

/// Why Kill Process does not end a process.
public enum TaskManagerKillRefusal: Sendable, Equatable {
    /// The text is not a pid or `host:pid`.
    case invalid
    /// The process runs on another machine (this slice ends local processes only).
    case remoteHost
    /// The cmux app itself.
    case appProcess
    /// A cmux-tui daemon: ending it would end every terminal it owns.
    case daemonProcess
    /// No such process is running.
    case notRunning
    /// cmux did not start it.
    case notCmuxProcess
    /// The signal could not be sent.
    case signalFailed

    /// The localized reason the palette, the CLI and the page show.
    public var message: String {
        switch self {
        case .invalid: TaskManagerStrings.refusalInvalid
        case .remoteHost: TaskManagerStrings.refusalRemote
        case .appProcess: TaskManagerStrings.refusalApp
        case .daemonProcess: TaskManagerStrings.refusalDaemon
        case .notRunning: TaskManagerStrings.refusalNotRunning
        case .notCmuxProcess: TaskManagerStrings.refusalNotCmux
        case .signalFailed: TaskManagerStrings.refusalSignal
        }
    }
}
