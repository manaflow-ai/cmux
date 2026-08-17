#if os(iOS) && DEBUG

/// DEBUG-only observation of which route a coordinator's most recent
/// configuration update took. The coordinator owns the state directly, so
/// each test instance is isolated without a process-global registry.
extension WorkspaceListTableCoordinator {
    /// How one configuration update reached the table.
    enum PayloadApplyRoute: Equatable {
        /// No row renders differently; the table was not touched.
        case noChange
        /// Payload-only changes with stable heights; the visible changed
        /// cells were re-configured in place, listed here by item id.
        case reconfiguredInPlace([String])
        /// Native swipe actions changed on the row UIKit is still editing.
        /// The listed cells stay untouched until the swipe closes.
        case deferredNativeActionReload([String])
        /// Structure or a row height changed; a snapshot was applied.
        case tableReload
    }

    func recordPayloadApplyRoute(_ route: PayloadApplyRoute) {
        lastPayloadApplyRoute = route
    }
}
#endif
