import AppKit
import CmuxAppKitSupportUI
import CmuxCore
import CmuxWorkspaces
import SwiftUI

/// App-target implementer of ``TmuxWorkspacePaneOverlayTarget`` for
/// ``TmuxWorkspacePaneOverlayController``/``TmuxWorkspacePaneOverlayRegistry``.
/// Owns every step the package cannot perform: resolving the window
/// content-overlay target (`AppWindowChromeComposition`), constructing the
/// shared `PassthroughOverlayContainerView` with the overlay-container
/// identifier, building the `NSHostingView<TmuxWorkspacePaneOverlayView>` that
/// owns the app-target `TmuxWorkspacePaneOverlayModel`, and translating a
/// ``CmuxCore/TmuxWorkspacePaneOverlayRenderState`` into a model update + root
/// view rebuild. Stateless; constructed once at the composition root.
@MainActor
final class AppTmuxWorkspacePaneOverlayTarget: TmuxWorkspacePaneOverlayTarget {
    func contentOverlayInstallationTarget(
        for window: NSWindow
    ) -> (container: NSView, reference: NSView)? {
        guard let target = AppWindowChromeComposition()
            .contentOverlayTargetResolver
            .installationTarget(for: window) else { return nil }
        return (container: target.container, reference: target.reference)
    }

    func makeOverlayContainerView() -> NSView {
        let containerView = PassthroughOverlayContainerView(frame: .zero)
        containerView.identifier = tmuxWorkspacePaneOverlayContainerIdentifier
        return containerView
    }

    func makeOverlayHostingView() -> NSView {
        TmuxWorkspacePaneOverlayHostingView()
    }

    func applyRenderState(_ state: TmuxWorkspacePaneOverlayRenderState, to hostingView: NSView) {
        guard let hostingView = hostingView as? TmuxWorkspacePaneOverlayHostingView else { return }
        hostingView.model.apply(state)
        hostingView.rootView = TmuxWorkspacePaneOverlayView(
            unreadRects: hostingView.model.unreadRects,
            flashRect: hostingView.model.flashRect,
            activePaneBorderRect: hostingView.model.activePaneBorderRect,
            activePaneBorderColorHex: hostingView.model.activePaneBorderColorHex,
            flashStartedAt: hostingView.model.flashStartedAt,
            flashReason: hostingView.model.flashReason
        )
    }

    func clearRenderState(on hostingView: NSView) {
        guard let hostingView = hostingView as? TmuxWorkspacePaneOverlayHostingView else { return }
        hostingView.model.clear()
        hostingView.rootView = TmuxWorkspacePaneOverlayView(
            unreadRects: [],
            flashRect: nil,
            activePaneBorderRect: nil,
            activePaneBorderColorHex: nil,
            flashStartedAt: nil,
            flashReason: nil
        )
    }
}

/// The app-target hosting view for the tmux pane overlay. Carries its own
/// ``TmuxWorkspacePaneOverlayModel`` so the package-owned controller can hold a
/// plain `NSView` while ``AppTmuxWorkspacePaneOverlayTarget`` updates the model
/// and rebuilds the root view in lock-step, exactly as the former
/// `WindowTmuxWorkspacePaneOverlayController` did with its paired
/// model/hosting-view pair.
@MainActor
final class TmuxWorkspacePaneOverlayHostingView: NSHostingView<TmuxWorkspacePaneOverlayView> {
    let model = TmuxWorkspacePaneOverlayModel()

    init() {
        super.init(
            rootView: TmuxWorkspacePaneOverlayView(
                unreadRects: [],
                flashRect: nil,
                activePaneBorderRect: nil,
                activePaneBorderColorHex: nil,
                flashStartedAt: nil,
                flashReason: nil
            )
        )
    }

    @available(*, unavailable)
    required init(rootView: TmuxWorkspacePaneOverlayView) {
        fatalError("init(rootView:) has not been implemented")
    }

    @available(*, unavailable)
    @MainActor required dynamic init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
