public import Foundation

/// Notification metadata attached to a terminal output push event.
///
/// The daemon inlines this payload alongside `terminal.output` when the session
/// produced a bell, finished a foreground command, or emitted an OSC-9
/// notification, so clients can surface a local or remote notification without a
/// separate round-trip.
public struct TerminalNotificationsPayload: Sendable, Equatable {
    /// Details about a foreground command that just finished.
    public struct CommandFinished: Sendable, Equatable {
        /// The command's exit code, if known.
        public let exitCode: Int?

        /// Creates a command-finished payload.
        /// - Parameter exitCode: The command's exit code, if known.
        public init(exitCode: Int?) {
            self.exitCode = exitCode
        }
    }

    /// An explicit notification emitted by the session (e.g. via OSC 9).
    public struct Notification: Sendable, Equatable {
        /// The notification title, if provided.
        public let title: String?
        /// The notification body, if provided.
        public let body: String?

        /// Creates a notification payload.
        /// - Parameters:
        ///   - title: The notification title, if provided.
        ///   - body: The notification body, if provided.
        public init(title: String?, body: String?) {
            self.title = title
            self.body = body
        }
    }

    /// Whether the session rang the terminal bell.
    public let bell: Bool
    /// The finished-command details, if a command finished.
    public let commandFinished: CommandFinished?
    /// The explicit notification, if one was emitted.
    public let notification: Notification?

    /// Creates a notifications payload.
    /// - Parameters:
    ///   - bell: Whether the bell rang.
    ///   - commandFinished: The finished-command details, if any.
    ///   - notification: The explicit notification, if any.
    public init(
        bell: Bool,
        commandFinished: CommandFinished?,
        notification: Notification?
    ) {
        self.bell = bell
        self.commandFinished = commandFinished
        self.notification = notification
    }
}
