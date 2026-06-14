/// Pure policy resolving how a mounted workspace should present based on whether
/// it is the selected or retiring workspace. Holds no state and touches no UI.
// lint:allow namespace-type — pure stateless policy/value namespace lifted verbatim from ContentView; no natural receiver, modernization deferred.
public enum MountedWorkspacePresentationPolicy {
    public static func resolve(
        isSelectedWorkspace: Bool,
        isRetiringWorkspace: Bool
    ) -> MountedWorkspacePresentation {
        let isRenderedVisible = isSelectedWorkspace || isRetiringWorkspace

        return MountedWorkspacePresentation(
            isRenderedVisible: isRenderedVisible,
            isPanelVisible: isRenderedVisible,
            renderOpacity: isRenderedVisible ? 1 : 0
        )
    }
}
