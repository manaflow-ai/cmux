/// The captured outcome of the multi-window window-route CLI flow: create a
/// named workspace in a second window, then list the workspaces of each window.
///
/// Produced by ``MultiWindowWindowRouteCoordinator/routeWindowWorkspace(title:window1Id:window2Id:)``.
/// Each field is one ``MultiWindowRouteResult`` from a CLI call run in order
/// (create, then list window 2, then list window 1). The multi-window UI-test
/// scaffolding maps these verbatim into its shared test-data file, so the
/// number, order, and meaning of the calls are part of the wire contract and
/// are frozen.
public struct MultiWindowWindowRouteOutcome: Sendable, Equatable {
    /// The result of `new-workspace --window <window2> --name <title> --focus false`.
    public let create: MultiWindowRouteResult
    /// The result of `list-workspaces --window <window2>` (JSON, uuid ids).
    public let window2List: MultiWindowRouteResult
    /// The result of `list-workspaces --window <window1>` (JSON, uuid ids).
    public let window1List: MultiWindowRouteResult

    /// Creates a window-route outcome.
    /// - Parameters:
    ///   - create: The create-workspace call result.
    ///   - window2List: The second-window list-workspaces call result.
    ///   - window1List: The first-window list-workspaces call result.
    public init(
        create: MultiWindowRouteResult,
        window2List: MultiWindowRouteResult,
        window1List: MultiWindowRouteResult
    ) {
        self.create = create
        self.window2List = window2List
        self.window1List = window1List
    }
}
