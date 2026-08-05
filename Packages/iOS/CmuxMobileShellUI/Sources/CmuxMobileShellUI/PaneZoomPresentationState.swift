import CMUXMobileCore
import CmuxMobileTerminal
import SwiftUI
#if os(iOS)
import UIKit
#endif

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

    mutating func layoutAvailabilityDidChange(hasLayout: Bool) {
        guard !hasLayout else { return }
        presentationDidChange(isTerminalPresented: true)
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
    let terminalTheme: TerminalTheme
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
        .background {
            terminalTheme.terminalBackgroundColor
                .ignoresSafeArea()
        }
        #if os(iOS)
        .background {
            PaneZoomNavigationHostBackground(
                color: terminalTheme.terminalBackgroundUIColor
            )
        }
        #endif
        // Tab-bar visibility is owned by the shell's per-route policy
        // (WorkspaceShellView). Hiding it here too would override the split
        // layout's explicit `.visible` detail policy from deeper in the same
        // subtree, collapsing the iPad tab bar for pane-enabled workspaces.
    }

    private var navigationPath: Binding<[PaneZoomPresentationState.Endpoint]> {
        Binding(
            get: { presentation.navigationPath },
            set: { presentation.navigationPathDidChange($0) }
        )
    }
}

#if os(iOS)
private struct PaneZoomNavigationHostBackground: UIViewRepresentable {
    let color: UIColor

    func makeUIView(context: Context) -> PaneZoomNavigationBackgroundBridgeView {
        let view = PaneZoomNavigationBackgroundBridgeView()
        view.color = color
        return view
    }

    func updateUIView(
        _ uiView: PaneZoomNavigationBackgroundBridgeView,
        context: Context
    ) {
        uiView.color = color
        uiView.applyBackground()
    }

    static func dismantleUIView(
        _ uiView: PaneZoomNavigationBackgroundBridgeView,
        coordinator: ()
    ) {
        uiView.restoreBackgrounds()
    }
}

final class PaneZoomNavigationBackgroundBridgeView: UIView {
    @MainActor private final class BackgroundSnapshot {
        weak var view: UIView?
        let originalColor: UIColor?
        var appliedColor: UIColor?

        init(view: UIView) {
            self.view = view
            self.originalColor = view.backgroundColor
        }
    }

    private var backgroundSnapshots: [ObjectIdentifier: BackgroundSnapshot] = [:]

    var color: UIColor = .clear {
        didSet { applyBackground() }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        applyBackground()
    }

    override func didMoveToSuperview() {
        super.didMoveToSuperview()
        applyBackground()
    }

    func applyBackground() {
        backgroundColor = .clear
        guard window != nil else {
            restoreBackgrounds()
            return
        }

        var ancestor = superview
        var hops = 0
        while let view = ancestor, !(view is UIWindow), hops < 16 {
            applyColor(to: view)
            ancestor = view.superview
            hops += 1
        }

        var responder: UIResponder? = self
        var responderHops = 0
        while let current = responder, responderHops < 32 {
            if let viewController = current as? UIViewController {
                applyColor(to: viewController.view)
                if let navigationView = viewController.navigationController?.view {
                    applyColor(to: navigationView)
                }
            }
            if let navigationController = current as? UINavigationController {
                applyColor(to: navigationController.view)
            }
            responder = current.next
            responderHops += 1
        }
    }

    func restoreBackgrounds() {
        for snapshot in backgroundSnapshots.values {
            guard let view = snapshot.view,
                  view.backgroundColor == snapshot.appliedColor else {
                continue
            }
            view.backgroundColor = snapshot.originalColor
        }
        backgroundSnapshots.removeAll()
    }

    private func applyColor(to view: UIView) {
        let key = ObjectIdentifier(view)
        let snapshot = backgroundSnapshots[key] ?? BackgroundSnapshot(view: view)
        snapshot.appliedColor = color
        backgroundSnapshots[key] = snapshot
        view.backgroundColor = color
    }
}
#endif
