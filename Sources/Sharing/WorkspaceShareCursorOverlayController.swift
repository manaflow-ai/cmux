import AppKit
import CmuxCanvasUI
import SwiftUI

@MainActor
final class WorkspaceShareCursorOverlayController {
    private weak var window: NSWindow?
    private let containerView = PassthroughWindowOverlayContainerView(frame: .zero)
    private let hostingView: NSHostingView<WorkspaceShareCursorOverlayView>
    private let chromeComposition = AppWindowChromeComposition()
    private var installConstraints: [NSLayoutConstraint] = []
    private weak var installedReferenceView: NSView?
    private var pointersByConnectionID: [String: WorkspaceShareRemotePointer] = [:]
    private var messagesByUserID: [String: String] = [:]
    private var containerFrame: CGRect = .zero
    private weak var canvasRootView: CanvasRootView?
    private var canvasBounds: CGRect?

    init(window: NSWindow?) {
        self.window = window
        hostingView = NSHostingView(rootView: WorkspaceShareCursorOverlayView(
            pointers: [],
            messagesByUserID: [:],
            containerFrame: .zero
        ))
        containerView.translatesAutoresizingMaskIntoConstraints = false
        containerView.wantsLayer = true
        containerView.layer?.backgroundColor = NSColor.clear.cgColor
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
        render()
    }

    func update(pointer: WorkspaceShareRemotePointer) {
        pointersByConnectionID[pointer.participant.connectionId] = pointer
        render()
    }

    func update(message: WorkspaceShareChatMessage) {
        messagesByUserID[message.userId] = message.text
        render()
    }

    func replaceChat(messages: [WorkspaceShareChatMessage]) {
        messagesByUserID = Dictionary(
            messages.suffix(50).map { ($0.userId, $0.text) },
            uniquingKeysWith: { _, latest in latest }
        )
        render()
    }

    func remove(connectionID: String) {
        pointersByConnectionID[connectionID] = nil
        render()
    }

    func update(containerFrame: CGRect) {
        canvasRootView = nil
        canvasBounds = nil
        self.containerFrame = containerFrame
        render()
    }

    func update(canvasRootView: CanvasRootView, canvasBounds: CGRect) {
        self.canvasRootView = canvasRootView
        self.canvasBounds = canvasBounds
        render()
    }

    func clear() {
        pointersByConnectionID.removeAll()
        messagesByUserID.removeAll()
        canvasRootView = nil
        canvasBounds = nil
        containerFrame = .zero
        render()
    }

    func uninstall() {
        clear()
        NSLayoutConstraint.deactivate(installConstraints)
        installConstraints.removeAll()
        containerView.removeFromSuperview()
        installedReferenceView = nil
    }

    private func render() {
        guard ensureInstalled() else { return }
        hostingView.rootView = WorkspaceShareCursorOverlayView(
            pointers: pointersByConnectionID.values.sorted { $0.id < $1.id },
            messagesByUserID: messagesByUserID,
            containerFrame: resolvedContainerFrame()
        )
        containerView.isHidden = pointersByConnectionID.isEmpty
    }

    @discardableResult
    private func ensureInstalled() -> Bool {
        guard let window,
              let target = chromeComposition.contentOverlayTargetResolver.installationTarget(for: window) else {
            return false
        }
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

    private func resolvedContainerFrame() -> CGRect {
        guard let canvasRootView,
              let canvasBounds,
              let reference = installedReferenceView else {
            return containerFrame
        }
        let nativeRect = canvasRootView.convertCanvasRect(canvasBounds, to: reference)
        guard !reference.isFlipped else { return nativeRect }
        return CGRect(
            x: nativeRect.minX,
            y: reference.bounds.height - nativeRect.maxY,
            width: nativeRect.width,
            height: nativeRect.height
        )
    }
}
