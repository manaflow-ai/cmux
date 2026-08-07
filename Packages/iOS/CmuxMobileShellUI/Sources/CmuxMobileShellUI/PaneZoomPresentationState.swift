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

/// How a ``PaneZoomHost`` sits in the surrounding navigation hierarchy.
enum PaneZoomHosting {
    /// The workspace detail is a pushed destination of an ancestor
    /// `NavigationStack` (every compact shell push context: the workspaces
    /// tab, notifications, and notification search). Nesting another
    /// `NavigationStack` here makes it join the window's shared
    /// `NavigationAuthority`, whose queue then reconciles one stack's bound
    /// path against the other stack's column and force-`try!`s an
    /// `AnyNavigationPath.Error.comparisonTypeMismatch`
    /// (`NavigationColumnState.boundPathChange`), killing the app. Type-erasing
    /// the nested path to `NavigationPath` does not help: the misrouted
    /// comparison still throws, just on a later push. So in this hosting the
    /// terminal is a zoom `fullScreenCover`, which owns its own navigation
    /// context and never enters the ancestor's authority.
    case navigationPush
    /// The workspace detail owns its navigation column (the split view's
    /// detail on regular width, or a standalone host such as the panes
    /// fixture). A `NavigationStack` here is the documented column pattern,
    /// so the terminal stays a pushed route over the pane-map root.
    case column
}

/// Keeps the pane-map route local to a workspace destination. The parent
/// context still owns workspace-list navigation and its shared back button,
/// while the restored terminal is installed on top of the pane map from the
/// first frame. The hosting decides the mechanism: a zoom full-screen cover
/// under an ancestor stack, or a pushed route in an owned column stack.
struct PaneZoomHost<Root: View, Terminal: View>: View {
    @Binding var presentation: PaneZoomPresentationState
    let hosting: PaneZoomHosting
    let terminalTheme: TerminalTheme
    /// The matched-transition source id (the selected surface's pane-map tile).
    let zoomSourceID: String
    /// The namespace shared with the pane-map tiles' `matchedTransitionSource`.
    let zoomNamespace: Namespace.ID
    @ViewBuilder let root: () -> Root
    @ViewBuilder let terminal: () -> Terminal

    var body: some View {
        switch hosting {
        case .navigationPush:
            presentationHost
        case .column:
            columnStackHost
        }
        // Tab-bar visibility is owned by the shell's per-route policy
        // (WorkspaceShellView). Hiding it here too would override the split
        // layout's explicit `.visible` detail policy from deeper in the same
        // subtree, collapsing the iPad tab bar for pane-enabled workspaces.
    }

    /// Push hosting: the pane map renders directly in the ancestor stack's
    /// destination (using its navigation bar), and the terminal is a zoom
    /// full-screen cover with its own root-only stack for the shared toolbar.
    private var presentationHost: some View {
        root()
            .fullScreenCover(isPresented: isTerminalPresentedBinding) {
                terminalHost
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
    }

    private var terminalHost: some View {
        NavigationStack {
            terminal()
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
        .navigationTransition(.zoom(sourceID: zoomSourceID, in: zoomNamespace))
    }

    /// Column hosting: this component owns the stack, with the pane map as its
    /// root and the terminal pushed on the first frame.
    private var columnStackHost: some View {
        NavigationStack(path: navigationPath) {
            root()
                .navigationDestination(for: PaneZoomPresentationState.Endpoint.self) { endpoint in
                    if endpoint == .terminal {
                        terminal()
                            .navigationTransition(.zoom(sourceID: zoomSourceID, in: zoomNamespace))
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
    }

    private var isTerminalPresentedBinding: Binding<Bool> {
        Binding(
            get: { presentation.isTerminalPresented },
            set: { presentation.presentationDidChange(isTerminalPresented: $0) }
        )
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
