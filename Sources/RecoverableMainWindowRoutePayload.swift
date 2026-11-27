/// The mutually exclusive live, frozen, or teardown payload for an orphan route.
@MainActor
enum RecoverableMainWindowRoutePayload {
    case live(
        sidebar: SidebarState,
        sidebarSelection: SidebarSelectionState,
        frozenWindowDockSnapshot: SessionSplitContainerSnapshot?
    )
    case frozen(SessionWindowSnapshot)
    case teardown
}
