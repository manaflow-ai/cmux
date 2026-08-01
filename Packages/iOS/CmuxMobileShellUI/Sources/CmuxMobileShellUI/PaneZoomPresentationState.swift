import CMUXMobileCore
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
                color: UIColor(paneZoomTerminalBackground: terminalTheme)
            )
        }
        #endif
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

#if os(iOS)
private struct PaneZoomNavigationHostBackground: UIViewRepresentable {
    let color: UIColor

    func makeUIView(context: Context) -> BackgroundBridgeView {
        let view = BackgroundBridgeView()
        view.color = color
        return view
    }

    func updateUIView(_ uiView: BackgroundBridgeView, context: Context) {
        uiView.color = color
        uiView.applyBackground()
    }

    final class BackgroundBridgeView: UIView {
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
            guard window != nil else { return }

            var ancestor = superview
            var hops = 0
            while let view = ancestor, !(view is UIWindow), hops < 16 {
                view.backgroundColor = color
                ancestor = view.superview
                hops += 1
            }

            var responder: UIResponder? = self
            var responderHops = 0
            while let current = responder, responderHops < 32 {
                if let viewController = current as? UIViewController {
                    viewController.view.backgroundColor = color
                    viewController.navigationController?.view.backgroundColor = color
                }
                if let navigationController = current as? UINavigationController {
                    navigationController.view.backgroundColor = color
                }
                responder = current.next
                responderHops += 1
            }
        }
    }
}

private extension UIColor {
    convenience init(paneZoomTerminalBackground theme: TerminalTheme) {
        let fallback = TerminalTheme.monokai.background
        guard let rgb = TerminalTheme.rgbComponents(theme.background)
            ?? TerminalTheme.rgbComponents(fallback) else {
            self.init(white: 0, alpha: 1)
            return
        }
        self.init(
            red: CGFloat(rgb.red) / 255.0,
            green: CGFloat(rgb.green) / 255.0,
            blue: CGFloat(rgb.blue) / 255.0,
            alpha: 1
        )
    }
}
#endif
