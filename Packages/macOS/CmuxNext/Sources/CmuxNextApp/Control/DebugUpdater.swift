import AppKit
import CmuxNextControl
import CmuxNextSettings
import CmuxNextUpdater

/// `debug.updater {action: "relaunch"}` (DEV and NIGHTLY): drives the
/// updater's relaunch path exactly as Sparkle does before it relaunches
/// into an update, then terminates. R138 check update-relaunch-no-prompt.
@MainActor
enum DebugUpdater {
    static func run(_ params: [String: JSONValue], _ services: AppServices,
                    terminate: @escaping @MainActor () -> Void = DebugUpdater.terminate) throws -> JSONValue {
        .null
    }

    static func terminate() {
        RunLoop.main.perform(inModes: [.common]) { NSApp.terminate(nil) }
    }
}
