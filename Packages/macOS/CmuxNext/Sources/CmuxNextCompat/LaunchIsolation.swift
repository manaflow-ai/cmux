/// Whether a launch is a test or bench launch on a shared host, read once from its environment.
///
/// - ``noActivate`` (`CMUX_NEXT_NO_ACTIVATE=1`): the app never takes focus (agent preflights,
///   captures, most benches). It implies ``isolated``.
/// - ``isolated`` (`CMUX_NEXT_ISOLATED_LAUNCH=1`, or no-activate): the launch leaves the account
///   alone. It opens windows at the fixed test frame (`TestWindowPlacement`), never claims the
///   account's `cmux` shim (`LastAppCLIPointer`), takes no system-wide hot keys, never relaunches at
///   login, offers no browser import, and keeps a Debug hang alive for its evidence.
///
/// An isolated launch without no-activate may activate. idle-budget's shipping measurement mode
/// launches that way, so it measures an active app at the bench's fixed window.
public struct LaunchIsolation: Sendable, Equatable {
    /// The environment key of ``noActivate``.
    public static let noActivateKey = "CMUX_NEXT_NO_ACTIVATE"
    /// The environment key of an isolated launch that may activate.
    public static let isolatedKey = "CMUX_NEXT_ISOLATED_LAUNCH"

    /// The app never takes focus.
    public let noActivate: Bool
    /// The launch leaves the account alone (see the type).
    public let isolated: Bool

    public init(environment: [String: String]) {
        noActivate = environment[Self.noActivateKey] == "1"
        isolated = noActivate || environment[Self.isolatedKey] == "1"
    }
}
