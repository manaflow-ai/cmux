enum GhosttySemanticConsumer: CaseIterable, Sendable {
    case selectionCopy
    case search
    case artifactHitTesting
    case accessibility
    case openURL
    case titleUpdate
    case titleCopy
    case clipboardRead
    case clipboardWrite
}

extension GhosttySurfaceView {
    nonisolated static func allowsSemanticConsumer(
        _ consumer: GhosttySemanticConsumer,
        authoritativeGridActive: Bool
    ) -> Bool {
        _ = consumer
        return !authoritativeGridActive
    }
}
