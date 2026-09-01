import CmuxMobileWorkspace
import SwiftUI

#if os(iOS)
import UIKit

/// Expands the terminal surface under the safe area in compact landscape so the
/// live area fills edge-to-edge, driven by the pure
/// ``MobileTerminalSafeAreaExpansionPolicy``. The horizontal edge holding the
/// camera cutout (Dynamic Island / notch) keeps its safe-area inset so terminal
/// content never renders under the hardware; the hosting window's interface
/// orientation decides which edge that is.
private struct MobileCompactLandscapeTerminalSafeAreaCompensation: ViewModifier {
    let context: MobileTerminalSafeAreaContext
    let includesBottom: Bool
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.layoutDirection) private var layoutDirection
    @State private var windowOrientation: MobileTerminalWindowOrientation = .unknown

    func body(content: Content) -> some View {
        let edges = MobileTerminalSafeAreaExpansionPolicy.edges(
            context: context,
            hasCompactVerticalSize: verticalSizeClass == .compact,
            cameraEdge: MobileTerminalLandscapeCameraEdgeResolver.edge(
                for: windowOrientation,
                isRightToLeft: layoutDirection == .rightToLeft
            ),
            includesBottom: includesBottom
        )
        Group {
            if edges.hasEdges {
                content
                    .ignoresSafeArea(.container, edges: edges.edgeSet)
            } else {
                content
            }
        }
        .background {
            MobileTerminalWindowOrientationReader { orientation in
                windowOrientation = orientation
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }
}

extension View {
    /// Expands the terminal under the safe area per the expansion policy.
    func mobileTerminalSafeAreaExpansion(
        context: MobileTerminalSafeAreaContext,
        includesBottom: Bool = true
    ) -> some View {
        modifier(MobileCompactLandscapeTerminalSafeAreaCompensation(
            context: context,
            includesBottom: includesBottom
        ))
    }
}

/// Feeds the hosting window's interface orientation into SwiftUI state.
///
/// SwiftUI exposes no interface orientation, and a landscape phone's horizontal
/// safe-area insets are symmetric, so the insets alone cannot say which edge
/// the camera cutout occupies. A hidden child view controller is the smallest
/// UIKit surface that both reads `UIWindowScene.interfaceOrientation` and hears
/// every rotation: layout passes cover window attach and 90° turns, and
/// `viewWillTransition(to:with:)` covers the 180° landscape flip, which changes
/// no bounds and therefore triggers no layout.
private struct MobileTerminalWindowOrientationReader: UIViewControllerRepresentable {
    let onChange: (MobileTerminalWindowOrientation) -> Void

    func makeUIViewController(context: Context) -> OrientationProbeViewController {
        OrientationProbeViewController(onChange: onChange)
    }

    func updateUIViewController(_ controller: OrientationProbeViewController, context: Context) {
        controller.onChange = onChange
    }
}

private final class OrientationProbeViewController: UIViewController {
    var onChange: (MobileTerminalWindowOrientation) -> Void
    private var lastReported: MobileTerminalWindowOrientation?

    init(onChange: @escaping (MobileTerminalWindowOrientation) -> Void) {
        self.onChange = onChange
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
    }

    override func viewWillLayoutSubviews() {
        super.viewWillLayoutSubviews()
        reportIfChanged()
    }

    override func viewWillTransition(
        to size: CGSize,
        with coordinator: any UIViewControllerTransitionCoordinator
    ) {
        super.viewWillTransition(to: size, with: coordinator)
        coordinator.animate(alongsideTransition: nil) { [weak self] _ in
            self?.reportIfChanged()
        }
    }

    private func reportIfChanged() {
        let orientation = Self.windowOrientation(
            from: view.window?.windowScene?.interfaceOrientation
        )
        guard orientation != lastReported else { return }
        lastReported = orientation
        let onChange = onChange
        // Layout callbacks can run while SwiftUI is mid-update; defer one hop
        // so the state write starts its own update instead of mutating this one.
        Task { @MainActor in
            onChange(orientation)
        }
    }

    private static func windowOrientation(
        from interfaceOrientation: UIInterfaceOrientation?
    ) -> MobileTerminalWindowOrientation {
        switch interfaceOrientation {
        case .portrait:
            return .portrait
        case .portraitUpsideDown:
            return .portraitUpsideDown
        case .landscapeLeft:
            return .landscapeLeft
        case .landscapeRight:
            return .landscapeRight
        case .unknown, nil:
            return .unknown
        @unknown default:
            return .unknown
        }
    }
}
#endif
