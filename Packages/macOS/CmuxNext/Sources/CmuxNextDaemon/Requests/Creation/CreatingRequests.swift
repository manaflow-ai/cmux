import Foundation

// What each creating command made, for `action.run`'s `created` list
// (DaemonCommandScope). Handles and keys are mapped to public ids by the
// control socket once the store applied the echo.

extension SurfaceCreated {
    var createdObjects: [DaemonCreatedObject] {
        [DaemonCreatedObject(.tab, surface.description)] + (terminalID.map { [DaemonCreatedObject(.terminal, $0.rawValue)] } ?? [])
    }
}

extension NewTabRequest: DaemonCreatingRequest {
    public func createdObjects(in response: SurfaceCreated) -> [DaemonCreatedObject] { response.createdObjects }
}

extension NewScreenRequest: DaemonCreatingRequest {
    public func createdObjects(in response: SurfaceCreated) -> [DaemonCreatedObject] { response.createdObjects }
}

extension SplitRequest: DaemonCreatingRequest {
    public func createdObjects(in response: SurfaceCreated) -> [DaemonCreatedObject] { response.createdObjects }
}

extension NewPaneRequest: DaemonCreatingRequest {
    public func createdObjects(in response: SurfaceCreated) -> [DaemonCreatedObject] { response.createdObjects }
}

extension NewColumnRequest: DaemonCreatingRequest {
    public func createdObjects(in response: SurfaceCreated) -> [DaemonCreatedObject] { response.createdObjects }
}

extension NewScreenWithSpecRequest: DaemonCreatingRequest {
    public func createdObjects(in response: Response) -> [DaemonCreatedObject] {
        (response.screen.map { [DaemonCreatedObject(.screen, $0.description)] } ?? [])
            + SurfaceCreated(surface: response.surface, terminalID: response.terminalID).createdObjects
    }
}

extension CreateTerminalRequest: DaemonCreatingRequest {
    public func createdObjects(in response: CreateTerminalResult) -> [DaemonCreatedObject] {
        (response.surface.map { [DaemonCreatedObject(.tab, $0.description)] } ?? [])
            + [DaemonCreatedObject(.terminal, response.terminalID.rawValue)]
    }
}

extension CreateWorkspaceRequest: DaemonCreatingRequest {
    public func createdObjects(in response: WorkspaceMutationResult) -> [DaemonCreatedObject] {
        [DaemonCreatedObject(.workspace, response.key.rawValue)]
    }
}

extension CreateTabGroupRequest: DaemonCreatingRequest {
    public func createdObjects(in response: TabGroupResult) -> [DaemonCreatedObject] {
        (response.group?.id ?? response.groupID).map { [DaemonCreatedObject(.tabGroup, $0.rawValue)] } ?? []
    }
}
