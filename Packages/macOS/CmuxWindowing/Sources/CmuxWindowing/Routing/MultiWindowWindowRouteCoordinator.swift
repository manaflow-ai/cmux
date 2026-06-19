public import Foundation

/// Runs the multi-window window-route CLI flow: create a named workspace in a
/// second window, then list each window's workspaces, capturing every call.
///
/// This is the CLI route flow extracted from AppDelegate's
/// `runMultiWindowWindowRouteCLIIfNeeded`: the app side still owns the env
/// gate, the shared UI-test data file, the bundled-CLI lookup, and the socket
/// health check, then constructs this coordinator and forwards. The coordinator
/// owns the three argument batches and their fixed run order, returning a
/// ``MultiWindowWindowRouteOutcome`` the app maps into its test-data file.
///
/// Isolation design: the coordinator holds only an immutable injected
/// ``MultiWindowRouting`` (itself `Sendable`), so there is no mutable state to
/// protect and it is a `Sendable` value type. Each call uses
/// ``MultiWindowRouting/routeCapturingLaunchFailure(arguments:)`` so a launch
/// failure on one call folds into a `-1` result without aborting the remaining
/// calls, byte-identical to the legacy capture.
public struct MultiWindowWindowRouteCoordinator: Sendable {
    private let router: any MultiWindowRouting

    /// Creates a coordinator over a routing seam.
    /// - Parameter router: The CLI router every call is dispatched through.
    public init(router: any MultiWindowRouting) {
        self.router = router
    }

    /// Creates a workspace named `title` in `window2Id`, then lists the
    /// workspaces of `window2Id` and `window1Id`, in that order.
    ///
    /// - Parameters:
    ///   - title: The new workspace name passed to `new-workspace --name`.
    ///   - window1Id: The first window whose workspaces are listed last.
    ///   - window2Id: The second window the workspace is created in and listed
    ///     first.
    /// - Returns: The ``MultiWindowWindowRouteOutcome`` holding all three
    ///   captured call results.
    public func routeWindowWorkspace(
        title: String,
        window1Id: UUID,
        window2Id: UUID
    ) async -> MultiWindowWindowRouteOutcome {
        let create = await router.routeCapturingLaunchFailure(
            arguments: [
                "new-workspace",
                "--window",
                window2Id.uuidString,
                "--name",
                title,
                "--focus",
                "false",
            ]
        )
        let window2List = await router.routeCapturingLaunchFailure(
            arguments: [
                "--json",
                "--id-format",
                "uuids",
                "list-workspaces",
                "--window",
                window2Id.uuidString,
            ]
        )
        let window1List = await router.routeCapturingLaunchFailure(
            arguments: [
                "--json",
                "--id-format",
                "uuids",
                "list-workspaces",
                "--window",
                window1Id.uuidString,
            ]
        )
        return MultiWindowWindowRouteOutcome(
            create: create,
            window2List: window2List,
            window1List: window1List
        )
    }
}
