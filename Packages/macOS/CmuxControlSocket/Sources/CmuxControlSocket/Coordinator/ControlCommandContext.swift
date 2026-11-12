/// The read-only seam through which ``ControlCommandCoordinator`` reaches live
/// app state to run control commands, without the package importing the app
/// target.
///
/// It is an umbrella of one protocol per command domain so the domains can be
/// built independently (each domain owns its own seam-protocol file and its own
/// app-conformance file). The coordinator stores `any ControlCommandContext`
/// and reaches every member through this inheritance. The app target (today
/// `TerminalController`, the interim composition owner; later
/// `TerminalControlComposition`) conforms by conforming to each constituent.
///
/// `AnyObject` so the coordinator can hold the conformer `weak` and avoid a
/// retain cycle with its composition owner.
@MainActor
public protocol ControlCommandContext:
    AnyObject,
    ControlWindowContext,
    ControlAppFocusContext,
    ControlFeedContext,
    ControlNotificationContext,
    ControlLayoutContext,
    ControlWorkspaceGroupContext,
    ControlWorkspaceTodoContext,
    ControlPaneContext,
    ControlCanvasContext,
    ControlSimulatorContext,
    ControlMobileHostContext,
    ControlWorkspaceContext,
    ControlSurfaceContext,
    ControlSystemContext,
    ControlProjectContext,
    ControlDebugContext,
    ControlSidebarContext,
    ControlBrowserPanelContext
{
    /// Revalidates relay provenance and live ownership immediately before an
    /// in-process command acts. Local requests without relay provenance pass.
    func controlRemoteRelayDispatchError(method: String, params: [String: JSONValue]) -> ControlCallResult?

    // MARK: Worker-lane resolution hop

    /// Runs a short closure synchronously on the main actor — the single hop
    /// of the coordinator's worker-lane resolution bodies (`surface.list`,
    /// `system.tree`, `surface.send_text`, …).
    ///
    /// The conformer MUST refresh its known `kind:N` refs before running the
    /// closure (the app forwards to `v2MainSync { v2RefreshKnownRefs(); … }`),
    /// mirroring the main-lane dispatch preamble byte-for-byte so
    /// caller-supplied refs resolve through the registry. The refresh covers
    /// only main-window workspace topology — dock-hosted surfaces are
    /// first-minted by each body's in-hop mint pass, so mint passes MUST
    /// preserve their payload's literal mint order; that ordering (not the
    /// refresh) is what keeps ordinals identical across lanes.
    /// Like `controlSidebarOnMain`, the hop collapses to an inline call
    /// when the caller is already on the main thread (mainThreadCallable
    /// in-process dispatch), and the closure receives the seam back as its
    /// main-actor parameter so callers never capture the non-Sendable seam
    /// existential off-main.
    nonisolated func controlResolveOnMain<T: Sendable>(
        _ body: @MainActor (any ControlCommandContext) -> T
    ) -> T
}

extension ControlCommandContext {
    /// Contexts without a relay authority must fail closed for relayed requests.
    public func controlRemoteRelayDispatchError(method: String, params: [String: JSONValue]) -> ControlCallResult? {
        guard params["_cmux_remote_workspace_id"] != nil else { return nil }
        return .err(code: "remote_relay_authentication_failed", message: "Relay request authentication failed", data: nil)
    }
}
