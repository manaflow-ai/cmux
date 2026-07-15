/// Enforces renderer suppression before authoritative streams can emit.
extension GhosttySurfaceRepresentable.Coordinator {
    nonisolated static func shouldBeginReplayForNewStream(authoritativeGridEnabled: Bool) -> Bool {
        authoritativeGridEnabled
    }

    nonisolated static func shouldUseRawRenderer(
        authoritativeGridEnabled: Bool,
        hasAuthoritativeGrid: Bool
    ) -> Bool {
        !authoritativeGridEnabled && !hasAuthoritativeGrid
    }

    nonisolated static func acceptsRawChunk(authoritativeGridEnabled: Bool, dataIsEmpty: Bool) -> Bool {
        !authoritativeGridEnabled || dataIsEmpty
    }

    nonisolated static func start<Result>(
        authoritativeGridEnabled: Bool,
        suppressPresentation: () -> Void,
        registerStreams: () -> Result
    ) -> Result {
        if shouldBeginReplayForNewStream(authoritativeGridEnabled: authoritativeGridEnabled) {
            suppressPresentation()
        }
        return registerStreams()
    }
}
