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
        switch params["action"]?.stringValue {
        case "relaunch":
            // What Sparkle does: the relaunch hook (the quit keeps every
            // session), then NSApp.terminate through applicationShouldTerminate.
            services.updater.updaterWillRelaunchApplication()
            terminate()
            return .object(["relaunching": true])
        default:
            throw ControlError.invalidParams("debug.updater: action must be \"relaunch\"")
        }
    }

    static func terminate() {
        RunLoop.main.perform(inModes: [.common]) { NSApp.terminate(nil) }
    }
}
