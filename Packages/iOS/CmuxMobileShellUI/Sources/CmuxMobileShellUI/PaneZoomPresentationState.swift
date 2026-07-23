/// Stable routing state for the native pane-map zoom presentation.
struct PaneZoomPresentationState: Equatable {
    enum Endpoint: Equatable {
        case paneMap
        case terminal
    }

    private(set) var endpoint: Endpoint = .terminal
    private(set) var sourceSurfaceID: String?

    var isTerminalPresented: Bool {
        endpoint == .terminal
    }

    mutating func presentPaneMap(from surfaceID: String?) {
        if let surfaceID, !surfaceID.isEmpty {
            sourceSurfaceID = surfaceID
        }
        endpoint = .paneMap
    }

    mutating func presentTerminal(surfaceID: String) {
        guard !surfaceID.isEmpty else { return }
        sourceSurfaceID = surfaceID
        endpoint = .terminal
    }

    mutating func presentationDidChange(isTerminalPresented: Bool) {
        endpoint = isTerminalPresented ? .terminal : .paneMap
    }
}
