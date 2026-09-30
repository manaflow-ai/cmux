import CmuxNextControl
import Foundation

/// How this process was launched. Identity (bundle, tag, control socket)
/// comes from the app bundle only (`LaunchIdentity`); inherited `CMUX_*`
/// variables were stripped in `CmuxNextApp.main` before this is read.
struct AppEnvironment: Sendable {
    let launch: LaunchIdentity
    /// `CMUX_NEXT_NO_ACTIVATE=1`: never take focus from the user's frontmost
    /// app (agent preflights and background launches). Windows open ordered
    /// back and the app never activates itself.
    let noActivate: Bool
    /// `CMUX_NEXT_TEST_WINDOW_SCREEN` / `CMUX_NEXT_TEST_WINDOW_FRAME` with
    /// no-activate: where windows open for agent screenshots.
    let testWindow: TestWindowPlacement?
    /// Mark this run for crash recovery (`AppRunMarker`): only the real app
    /// process, never tests that build `AppServices`.
    var marksRun = false

    var tag: String? { launch.tag }

    static func current(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> AppEnvironment {
        let noActivate = environment["CMUX_NEXT_NO_ACTIVATE"] == "1"
        return AppEnvironment(
            launch: LaunchIdentity.current(),
            noActivate: noActivate,
            testWindow: TestWindowPlacement.parse(environment, noActivate: noActivate)
        )
    }
}
