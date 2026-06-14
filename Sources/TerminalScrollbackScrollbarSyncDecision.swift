struct TerminalScrollbackScrollbarSyncDecision: Equatable {
    let intent: TerminalScrollbackViewportIntent
    let allowExplicitScrollbarSync: Bool
    let shouldSynchronizeViewport: Bool
}
