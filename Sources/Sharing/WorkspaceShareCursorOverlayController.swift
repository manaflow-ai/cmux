import AppKit
import CmuxCanvasUI
import SwiftUI

@MainActor
final class WorkspaceShareCursorOverlayController {
    private weak var window: NSWindow?
    private let containerView = PassthroughWindowOverlayContainerView(frame: .zero)
    private let hostingView: NSHostingView<WorkspaceShareCursorOverlayView>
    private let onSendChat: @MainActor (String) -> Void
    private lazy var chatHostingView = NSHostingView(rootView: WorkspaceShareChatOverlayView(
        messages: [],
        onSend: onSendChat
    ))
    private let chromeComposition = AppWindowChromeComposition()
    private var installConstraints: [NSLayoutConstraint] = []
    private var chatInstallConstraints: [NSLayoutConstraint] = []
    private weak var installedReferenceView: NSView?
    private weak var chatInstalledReferenceView: NSView?
    private var pointersByConnectionID: [String: WorkspaceShareRemotePointer] = [:]
    private var messagesByUserID: [String: String] = [:]
    private var chatMessages: [WorkspaceShareChatMessage] = []
    private var containerFrame: CGRect = .zero
    private weak var canvasRootView: CanvasRootView?
    private var canvasBounds: CGRect?
    private var sharingActive = false

    init(window: NSWindow?, onSendChat: @escaping @MainActor (String) -> Void) {
        self.window = window
        self.onSendChat = onSendChat
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
        if !chatMessages.contains(where: { $0.id == message.id }) {
            chatMessages.append(message)
            chatMessages = Array(chatMessages.suffix(50))
        }
        render()
    }

    func replaceChat(messages: [WorkspaceShareChatMessage]) {
        chatMessages = Array(messages.suffix(50))
        messagesByUserID = Dictionary(
            chatMessages.map { ($0.userId, $0.text) },
            uniquingKeysWith: { _, latest in latest }
        )
        render()
    }

    func setSharingActive(_ active: Bool) {
        sharingActive = active
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
        chatMessages.removeAll()
        canvasRootView = nil
        canvasBounds = nil
        containerFrame = .zero
        sharingActive = false
        render()
    }

    func uninstall() {
        clear()
        NSLayoutConstraint.deactivate(installConstraints)
        installConstraints.removeAll()
        containerView.removeFromSuperview()
        NSLayoutConstraint.deactivate(chatInstallConstraints)
        chatInstallConstraints.removeAll()
        chatHostingView.removeFromSuperview()
        installedReferenceView = nil
        chatInstalledReferenceView = nil
    }

    private func render() {
        guard ensureInstalled() else { return }
        hostingView.rootView = WorkspaceShareCursorOverlayView(
            pointers: pointersByConnectionID.values.sorted { $0.id < $1.id },
            messagesByUserID: messagesByUserID,
            containerFrame: resolvedContainerFrame()
        )
        containerView.isHidden = pointersByConnectionID.isEmpty
        chatHostingView.rootView = WorkspaceShareChatOverlayView(
            messages: chatMessages,
            onSend: onSendChat
        )
        chatHostingView.isHidden = !sharingActive
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
        if sharingActive,
           chatHostingView.superview !== target.container || chatInstalledReferenceView !== target.reference {
            NSLayoutConstraint.deactivate(chatInstallConstraints)
            chatInstallConstraints.removeAll()
            chatHostingView.removeFromSuperview()
            chatHostingView.translatesAutoresizingMaskIntoConstraints = false
            target.container.addSubview(chatHostingView, positioned: .above, relativeTo: target.reference)
            chatInstallConstraints = [
                chatHostingView.trailingAnchor.constraint(equalTo: target.reference.trailingAnchor, constant: -14),
                chatHostingView.bottomAnchor.constraint(equalTo: target.reference.bottomAnchor, constant: -14),
                chatHostingView.widthAnchor.constraint(equalToConstant: 292),
                chatHostingView.heightAnchor.constraint(equalToConstant: 230),
            ]
            NSLayoutConstraint.activate(chatInstallConstraints)
            chatInstalledReferenceView = target.reference
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
