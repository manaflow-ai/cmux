/// Diagnostic-only presentation and interaction state for one switch target.
struct WorkspaceSwitchReadiness: Equatable {
    let contentKind: WorkspaceSwitchContentKind
    var requiresInteraction: Bool
    var portalPresented: Bool
    var firstFramePresented: Bool
    var interactionReady: Bool

    /// Whether the destination has produced the presentation signals relevant
    /// to its content kind. This never controls mounted-workspace ownership.
    var presentationIsReady: Bool {
        switch contentKind {
        case .terminal:
            return portalPresented && firstFramePresented
        case .browser:
            return portalPresented
        case .passive:
            return true
        }
    }

    var interactionIsReady: Bool {
        !requiresInteraction || interactionReady
    }
}
