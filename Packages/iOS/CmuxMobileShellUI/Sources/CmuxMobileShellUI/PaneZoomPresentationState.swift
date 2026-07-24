import SwiftUI

/// Stable routing state for the native pane-map zoom presentation.
struct PaneZoomPresentationState: Equatable {
    enum Endpoint: Hashable {
        case paneMap
        case terminal
    }

    private(set) var navigationPath: [Endpoint] = [.terminal]
    private(set) var sourceSurfaceID: String?

    var endpoint: Endpoint {
        navigationPath.last == .terminal ? .terminal : .paneMap
    }

    var isTerminalPresented: Bool {
        endpoint == .terminal
    }

    mutating func presentPaneMap(from surfaceID: String?) {
        if let surfaceID, !surfaceID.isEmpty {
            sourceSurfaceID = surfaceID
        }
        navigationPath = []
    }

    mutating func presentTerminal(surfaceID: String) {
        guard !surfaceID.isEmpty else { return }
        sourceSurfaceID = surfaceID
        navigationPath = [.terminal]
    }

    mutating func presentationDidChange(isTerminalPresented: Bool) {
        navigationPath = isTerminalPresented ? [.terminal] : []
    }

    mutating func navigationPathDidChange(_ path: [Endpoint]) {
        navigationPath = path.last == .terminal ? [.terminal] : []
    }
}

/// Keeps the pane-map route local to a workspace destination. The parent stack
/// still owns workspace-list navigation and its shared back button, while this
/// path starts with the restored terminal already installed on the first frame.
struct PaneZoomNavigationStack<Root: View, Terminal: View>: View {
    @Binding var presentation: PaneZoomPresentationState
    @ViewBuilder let root: () -> Root
    @ViewBuilder let terminal: () -> Terminal

    var body: some View {
        NavigationStack(path: navigationPath) {
            root()
                .navigationDestination(for: PaneZoomPresentationState.Endpoint.self) { endpoint in
                    if endpoint == .terminal {
                        terminal()
                    }
                }
        }
        #if os(iOS)
        .toolbarVisibility(.hidden, for: .tabBar)
        #endif
    }

    private var navigationPath: Binding<[PaneZoomPresentationState.Endpoint]> {
        Binding(
            get: { presentation.navigationPath },
            set: { presentation.navigationPathDidChange($0) }
        )
    }
}
