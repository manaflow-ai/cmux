import AppKit
import ObjectiveC
import SwiftUI

private var tmuxWorkspacePaneWindowOverlayKey: UInt8 = 0
private let tmuxWorkspacePaneOverlayContainerIdentifier = NSUserInterfaceItemIdentifier("cmux.tmuxWorkspacePane.overlay.container")

@MainActor
final class WindowTmuxWorkspacePaneOverlayController: NSObject {
    private weak var window: NSWindow?
    private let containerView = PassthroughWindowOverlayContainerView(frame: .zero)
    private let model = TmuxWorkspacePaneOverlayModel()
    private let hostingView: NSHostingView<TmuxWorkspacePaneOverlayView>
    private let chromeComposition = AppWindowChromeComposition()
    private var installConstraints: [NSLayoutConstraint] = []
    private weak var installedReferenceView: NSView?
    private var lastRenderState: TmuxWorkspacePaneOverlayRenderState?
    private var pendingGeometryRefresh = false

    var hasRenderedState: Bool {
        lastRenderState != nil || !containerView.isHidden
    }

    static func controller(for window: NSWindow, createIfNeeded: Bool) -> WindowTmuxWorkspacePaneOverlayController? {
        if let existing = objc_getAssociatedObject(window, &tmuxWorkspacePaneWindowOverlayKey) as? WindowTmuxWorkspacePaneOverlayController {
            return existing
        }
        guard createIfNeeded else { return nil }
        let controller = WindowTmuxWorkspacePaneOverlayController(window: window)
        objc_setAssociatedObject(window, &tmuxWorkspacePaneWindowOverlayKey, controller, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return controller
    }

    init(window: NSWindow) {
        self.window = window
        self.hostingView = NSHostingView(
            rootView: TmuxWorkspacePaneOverlayView(
                unreadRects: [],
                flashRect: nil,
                activePaneBorderRect: nil,
                activePaneBorderColorHex: nil,
                flashStartedAt: nil,
                flashReason: nil
            )
        )
        super.init()
        containerView.translatesAutoresizingMaskIntoConstraints = false
        containerView.wantsLayer = true
        containerView.layer?.backgroundColor = NSColor.clear.cgColor
        containerView.isHidden = true
        containerView.alphaValue = 0
        containerView.identifier = tmuxWorkspacePaneOverlayContainerIdentifier
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = NSColor.clear.cgColor
        containerView.addSubview(hostingView)
        NSLayoutConstraint.activate([
            hostingView.topAnchor.constraint(equalTo: containerView.topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: containerView.bottomAnchor),
            hostingView.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
        ])
        _ = ensureInstalled()
    }

    @discardableResult
    private func ensureInstalled() -> Bool {
        guard let window,
              let target = chromeComposition
                .contentOverlayTargetResolver
                .installationTarget(for: window) else { return false }

        if containerView.superview !== target.container || installedReferenceView !== target.reference {
            NSLayoutConstraint.deactivate(installConstraints)
            installConstraints.removeAll()
            containerView.removeFromSuperview()
            target.container.addSubview(containerView, positioned: .above, relativeTo: target.reference)
            installConstraints = [
                containerView.topAnchor.constraint(equalTo: target.reference.topAnchor),
                containerView.bottomAnchor.constraint(equalTo: target.reference.bottomAnchor),
                containerView.leadingAnchor.constraint(equalTo: target.reference.leadingAnchor),
                containerView.trailingAnchor.constraint(equalTo: target.reference.trailingAnchor),
            ]
            NSLayoutConstraint.activate(installConstraints)
            installedReferenceView = target.reference
        }

        return true
    }

    func update(state: TmuxWorkspacePaneOverlayRenderState?) {
        guard ensureInstalled() else { return }

        if state == nil, lastRenderState == nil, containerView.isHidden {
            return
        }
        if let state, state == lastRenderState {
            return
        }

        if let state {
            lastRenderState = state
            model.apply(state)
            hostingView.rootView = TmuxWorkspacePaneOverlayView(
                unreadRects: model.unreadRects,
                flashRect: model.flashRect,
                activePaneBorderRect: model.activePaneBorderRect,
                activePaneBorderColorHex: model.activePaneBorderColorHex,
                flashStartedAt: model.flashStartedAt,
                flashReason: model.flashReason
            )
            containerView.alphaValue = 1
            containerView.isHidden = false
        } else {
            lastRenderState = nil
            model.clear()
            hostingView.rootView = TmuxWorkspacePaneOverlayView(
                unreadRects: [],
                flashRect: nil,
                activePaneBorderRect: nil,
                activePaneBorderColorHex: nil,
                flashStartedAt: nil,
                flashReason: nil
            )
            containerView.alphaValue = 0
            containerView.isHidden = true
        }
    }

    func scheduleGeometryRefresh(stateProvider: @MainActor @escaping () -> TmuxWorkspacePaneOverlayRenderState?) {
        guard !pendingGeometryRefresh else { return }
        pendingGeometryRefresh = true
        // Divider drags can emit many geometry snapshots; one overlay update per
        // main-actor turn is enough to keep the active border aligned.
        Task { @MainActor [weak self] in
            guard let self else { return }
            pendingGeometryRefresh = false
            update(state: stateProvider())
        }
    }
}
