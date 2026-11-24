public import CmuxNextActions

/// The scripted quits and `cmux app relaunch` (`relaunchKeepSessions`; Leo, 2026-11-22: "approved ways
/// to simply do the update and restart button's flow should be available"). Relaunch quits as asked and
/// opens the bundle installed now, the newer build a nightly put under the running app included. Its
/// catalog row shipped before any handler, so every build answered "relaunchKeepSessions has no handler
/// in this build" and no agent could restart the app (cmux#53047).
public struct QuitActions {
    public init() {}
    public enum RelaunchDecision: Equatable, Sendable {
        /// Quit with this choice; a helper opens the bundle once the process has exited.
        case relaunch(QuitSessionsChoice)
        case refuse(String)
    }

    public static let notNewer = "the installed build is the running build; --if-newer relaunches only into a newer one"
    public static let helperFailed = "cmux could not start the helper that opens it again, so it did not quit"

    /// `keepSessions` defaults to keep (the action's title); `false` ends the local sessions and keeps
    /// the layout, as Quit and End Sessions does. `ifNewer` refuses when no newer build is installed.
    public static func decideRelaunch(_ invocation: ActionInvocation, newerInstalled: Bool) -> RelaunchDecision {
        if invocation["ifNewer"]?.boolValue == true, !newerInstalled { return .refuse(notNewer) }
        return .relaunch(invocation["keepSessions"]?.boolValue == false ? .endKeepLayout : .keep)
    }

    /// Binds Quit and Keep Sessions, Quit and End Sessions, Quit and End Everything and Relaunch.
    /// `quit` starts a quit with that choice; `newerInstalled` reads the bundle on disk now;
    /// `startRelaunchHelper` starts the helper that opens the app again (false: it could not, and the
    /// app stays). The helper starts before the quit, so a relaunch never leaves the app closed.
    @MainActor public static func bind(_ registry: ActionRegistry, quit: @escaping @MainActor (QuitSessionsChoice) -> Void,
                                       newerInstalled: @escaping @MainActor () -> Bool,
                                       startRelaunchHelper: @escaping @MainActor () -> Bool) {
        registry.bindEffect("quitKeepSessions") { _ in quit(.keep); return .done }
        registry.bindEffect("quitEndSessions") { _ in quit(.endKeepLayout); return .done }
        registry.bindEffect("quitEndEverything") { _ in quit(.endEverything); return .done }
        registry.bindEffect("relaunchKeepSessions") { invocation in
            switch decideRelaunch(invocation, newerInstalled: newerInstalled()) {
            case .refuse(let reason): return .refused(reason)
            case .relaunch(let choice):
                guard startRelaunchHelper() else { return .refused(helperFailed) }
                quit(choice)
                return .done
            }
        }
    }
}
