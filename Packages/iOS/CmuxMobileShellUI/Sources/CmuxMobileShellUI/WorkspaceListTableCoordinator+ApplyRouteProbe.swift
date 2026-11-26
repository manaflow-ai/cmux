#if os(iOS) && DEBUG

/// DEBUG-only observation of how a coordinator's most recent reconcile reached
/// the table. The coordinator owns the state directly, so each test instance
/// is isolated without a process-global registry.
extension WorkspaceListTableCoordinator {
    enum PayloadApplyRoute: Equatable {
        /// No row renders differently; the table was not touched.
        case noChange
        /// Content changes that keep every row's height, written into the
        /// listed rows' live cells without table layout.
        case contentInPlace([String])
        /// Geometry changed while the user was moving the list. The listed
        /// rows' content reached their cells; geometry waits for the gesture.
        case geometryDeferred(contentUpdatedIDs: [String])
        /// Identities, order, heights and native actions were committed.
        case geometryCommitted
    }
}
#endif
