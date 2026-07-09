public import Foundation

/// Runs the user-configured shell command when a terminal notification is
/// delivered, exposing the notification fields to that command through
/// `CMUX_NOTIFICATION_TITLE`/`CMUX_NOTIFICATION_SUBTITLE`/`CMUX_NOTIFICATION_BODY`
/// environment variables.
///
/// Owns the custom-command sub-domain: the `notificationCustomCommand` Defaults
/// key, its empty default, the serial dispatch queue, and the `/bin/sh -c`
/// spawn. A single runner instance must back every notification so commands
/// serialize on one queue, matching the legacy shared `customCommandQueue`; the
/// app holds that shared instance at its composition point and injects the
/// `UserDefaults` the command string is read from.
public struct NotificationCustomCommandRunner: Sendable {
    /// `UserDefaults` key the custom command string is stored under.
    public static let defaultsKey = "notificationCustomCommand"

    /// Default custom command (empty, i.e. no command configured).
    public static let defaultCommand = ""

    private let queue: DispatchQueue

    public init() {
        queue = DispatchQueue(
            label: "com.cmuxterm.notification-custom-command",
            qos: .utility
        )
    }

    /// Reads the configured custom command from the injected `defaults`
    /// (falling back to ``defaultCommand`` when unset) and runs it with the
    /// notification fields exported, mirroring ``run(command:title:subtitle:body:)``.
    public func run(title: String, subtitle: String, body: String, defaults: UserDefaults) {
        let command = defaults.string(forKey: Self.defaultsKey) ?? Self.defaultCommand
        run(command: command, title: title, subtitle: subtitle, body: body)
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
