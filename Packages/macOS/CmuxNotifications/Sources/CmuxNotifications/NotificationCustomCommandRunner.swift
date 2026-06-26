import Foundation

/// Runs the user-configured shell command when a terminal notification is
/// delivered, exposing the notification fields to that command through
/// `CMUX_NOTIFICATION_TITLE`/`CMUX_NOTIFICATION_SUBTITLE`/`CMUX_NOTIFICATION_BODY`
/// environment variables.
///
/// The command string and its Defaults wiring live app-side (the
/// `notificationCustomCommand` key and its empty default are owned by
/// `NotificationSoundSettings`); this runner only owns the serial dispatch
/// queue and the `/bin/sh -c` spawn. A single runner instance must back every
/// notification so commands serialize on one queue, matching the legacy shared
/// `customCommandQueue`.
public struct NotificationCustomCommandRunner: Sendable {
    private let queue: DispatchQueue

    public init() {
        queue = DispatchQueue(
            label: "com.cmuxterm.notification-custom-command",
            qos: .utility
        )
    }

    /// Spawns `/bin/sh -c <command>` on a utility queue with the notification
    /// fields exported as `CMUX_NOTIFICATION_*` environment variables. A
    /// `command` that is empty after trimming whitespace is ignored without
    /// dispatching.
    public func run(command: String, title: String, subtitle: String, body: String) {
        let command = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty else { return }
        queue.async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", command]
            var env = ProcessInfo.processInfo.environment
            env["CMUX_NOTIFICATION_TITLE"] = title
            env["CMUX_NOTIFICATION_SUBTITLE"] = subtitle
            env["CMUX_NOTIFICATION_BODY"] = body
            process.environment = env
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            do {
                try process.run()
            } catch {
                NSLog("Notification command failed to launch: \(error)")
            }
        }
    }
}
