import AppKit
import Foundation
import WebKit
extension Notification.Name {
    static let workspaceSwitchPresentationDidBecomeReady =
        Notification.Name("cmux.workspaceSwitchPresentationDidBecomeReady")
}
/// Owns one window's workspace-switch transaction from selection commit through
/// presentation and input readiness. The destination's frame observer is scoped
/// to that terminal and is installed before selection mutates the mounted tree.
@MainActor
final class WorkspaceSwitchCoordinator {
    enum ContentKind: String, Equatable {
        case terminal
        case browser
        case passive
    }
    struct Readiness: Equatable {
        let contentKind: ContentKind
        var requiresInteraction: Bool
        var portalPresented: Bool
        var firstFramePresented: Bool
        var interactionReady: Bool
        /// Source retirement is a visual handoff. Focus can settle afterward,
        /// and must never keep the old workspace mounted over a ready destination.
        var isReadyForSourceRetirement: Bool {
            switch contentKind {
            case .terminal:
                return portalPresented && firstFramePresented
            case .browser:
                return portalPresented
            case .passive:
                return true
            }
        }
        var interactionIsReady: Bool {
            !requiresInteraction || interactionReady
        }
    }
    struct PresentationTarget {
        let workspaceID: UUID
        let contentKind: ContentKind
        let terminalSurfaceID: UUID?
        let terminalView: GhosttyNSView?
        let terminalRendererPresented: Bool
        let terminalRenderedFrameSequence: UInt64
        let browserWebView: WKWebView?
        let portalPresented: Bool
        let interactionReady: Bool
        let requiresInteraction: Bool
    }

    private struct ActiveTransaction {
        let requestID: UUID
        let sourceWorkspaceID: UUID
        let targetWorkspaceID: UUID
        var targetSurfaceID: UUID?
        var targetTerminalViewID: ObjectIdentifier?
        var targetWebViewID: ObjectIdentifier?
        var readiness: Readiness?
        var sourceRetired = false
        var rendererProtectionActive = false
        var warmFrameAvailable = false
        var frameSequenceAtSelection: UInt64 = 0
        var observedFrameAfterSelection = false
        var frameObserver: NSObjectProtocol?
        var frameNotificationRelease: (() -> Void)?
        var selectionCommitInterval: DynamicTracingSignpostInterval?
        var portalShowInterval: DynamicTracingSignpostInterval?
        var portalHideInterval: DynamicTracingSignpostInterval?
        var rendererRealizationInterval: DynamicTracingSignpostInterval?
        var firstFrameInterval: DynamicTracingSignpostInterval?
        var interactiveInterval: DynamicTracingSignpostInterval?
    }
    private let notificationCenter: NotificationCenter
    private let beginRendererProtection: @MainActor (UUID, UUID) -> Void
    private let endRendererProtection: @MainActor (UUID) -> Void
    private var active: ActiveTransaction?
    init(
        notificationCenter: NotificationCenter = .default,
        beginRendererProtection: @escaping @MainActor (UUID, UUID) -> Void = {
            surfaceID,
            requestID in
            RendererRealizationController.shared.beginWorkspaceSwitchPresentationProtection(
                surfaceID: surfaceID,
                requestID: requestID
            )
        },
        endRendererProtection: @escaping @MainActor (UUID) -> Void = { requestID in
            RendererRealizationController.shared.endWorkspaceSwitchPresentationProtection(
                requestID: requestID
            )
        }
    ) {
        self.notificationCenter = notificationCenter
        self.beginRendererProtection = beginRendererProtection
        self.endRendererProtection = endRendererProtection
    }
    /// No transaction means there is no coordinated presentation to wait for.
    var isReadyForSourceRetirement: Bool {
        guard let active else { return true }
        return active.readiness?.isReadyForSourceRetirement == true
    }

    func selectionWillCommit(
        from sourceWorkspaceID: UUID?,
        to targetWorkspaceID: UUID?,
        targetSurfaceID: UUID?,
        targetTerminalView: GhosttyNSView?,
        targetRendererPresented: Bool,
        targetRenderedFrameSequence: UInt64
    ) {
        guard sourceWorkspaceID != targetWorkspaceID else { return }
        cancel()
        guard let sourceWorkspaceID,
              let targetWorkspaceID else {
            return
        }

        let requestID = UUID()
        let details = Self.details(
            requestID: requestID,
            sourceWorkspaceID: sourceWorkspaceID,
            targetWorkspaceID: targetWorkspaceID
        )
        var transaction = ActiveTransaction(
            requestID: requestID,
            sourceWorkspaceID: sourceWorkspaceID,
            targetWorkspaceID: targetWorkspaceID,
            selectionCommitInterval: workspaceSwitchSignposts.begin(
                "ws.switch.selection-commit",
                details
            ),
            interactiveInterval: workspaceSwitchSignposts.begin(
                "ws.switch.interactive",
                details
            )
        )
        if let targetSurfaceID {
            installTerminalTarget(
                surfaceID: targetSurfaceID,
                view: targetTerminalView,
                rendererPresented: targetRendererPresented,
                renderedFrameSequence: targetRenderedFrameSequence,
                in: &transaction,
                details: Self.details(
                    requestID: requestID,
                    sourceWorkspaceID: sourceWorkspaceID,
                    targetWorkspaceID: targetWorkspaceID,
                    contentKind: .terminal
                )
            )
        }
        active = transaction
    }

    func selectionDidCommit(from sourceWorkspaceID: UUID?, to targetWorkspaceID: UUID?) {
        guard var transaction = active,
              transaction.sourceWorkspaceID == sourceWorkspaceID,
              transaction.targetWorkspaceID == targetWorkspaceID else {
            return
        }
        workspaceSwitchSignposts.end(transaction.selectionCommitInterval)
        transaction.selectionCommitInterval = nil
        active = transaction
    }

    func beginPresentation(_ target: PresentationTarget) {
        guard var transaction = active,
              transaction.targetWorkspaceID == target.workspaceID else {
            return
        }

        reconcileTerminalTarget(
            surfaceID: target.terminalSurfaceID,
            view: target.terminalView,
            rendererPresented: target.terminalRendererPresented,
            renderedFrameSequence: target.terminalRenderedFrameSequence,
            in: &transaction
        )
        transaction.targetWebViewID = target.browserWebView.map(ObjectIdentifier.init)
        let firstFramePresented: Bool
        if target.contentKind == .terminal {
            firstFramePresented =
                transaction.warmFrameAvailable ||
                transaction.observedFrameAfterSelection
        } else {
            firstFramePresented = true
        }
        transaction.readiness = Readiness(
            contentKind: target.contentKind,
            requiresInteraction: target.requiresInteraction,
            portalPresented: target.portalPresented,
            firstFramePresented: firstFramePresented,
            interactionReady: target.interactionReady
        )

        let details = Self.details(
            requestID: transaction.requestID,
            sourceWorkspaceID: transaction.sourceWorkspaceID,
            targetWorkspaceID: transaction.targetWorkspaceID,
            contentKind: target.contentKind
        )
        if !target.portalPresented {
            transaction.portalShowInterval = workspaceSwitchSignposts.begin(
                "ws.switch.portal-show",
                details
            )
        } else {
            releaseRendererProtection(&transaction)
        }
        if firstFramePresented {
            finishFrameObservation(&transaction)
        }
        if target.interactionReady || !target.requiresInteraction {
            workspaceSwitchSignposts.end(transaction.interactiveInterval)
            transaction.interactiveInterval = nil
        }
        finishIfPossible(&transaction)
    }

    func noteTerminalPortalPresented(
        surfaceID: UUID,
        renderedFrameSequence: UInt64
    ) {
        guard var transaction = active,
              transaction.targetSurfaceID == surfaceID,
              var readiness = transaction.readiness else {
            return
        }
        let wasReady = readiness.isReadyForSourceRetirement
        if renderedFrameSequence > transaction.frameSequenceAtSelection {
            transaction.observedFrameAfterSelection = true
            readiness.firstFramePresented = true
            finishFrameObservation(&transaction)
        }
        readiness.portalPresented = true
        transaction.readiness = readiness
        workspaceSwitchSignposts.end(transaction.portalShowInterval)
        transaction.portalShowInterval = nil
        releaseRendererProtection(&transaction)
        let becameReady = !wasReady && readiness.isReadyForSourceRetirement
        finishIfPossible(&transaction)
        notifyPresentationReadyIfNeeded(becameReady)
    }

    func noteBrowserPortalPresented(webView: WKWebView) {
        guard var transaction = active,
              transaction.targetWebViewID == ObjectIdentifier(webView),
              var readiness = transaction.readiness else {
            return
        }
        let wasReady = readiness.isReadyForSourceRetirement
        readiness.portalPresented = true
        transaction.readiness = readiness
        workspaceSwitchSignposts.end(transaction.portalShowInterval)
        transaction.portalShowInterval = nil
        let becameReady = !wasReady && readiness.isReadyForSourceRetirement
        finishIfPossible(&transaction)
        notifyPresentationReadyIfNeeded(becameReady)
    }

    func noteFirstFrame(surfaceID: UUID) {
        guard var transaction = active,
              transaction.targetSurfaceID == surfaceID else {
            return
        }
        let wasReady = transaction.readiness?.isReadyForSourceRetirement == true
        transaction.observedFrameAfterSelection = true
        if var readiness = transaction.readiness {
            readiness.firstFramePresented = true
            transaction.readiness = readiness
        }
        finishFrameObservation(&transaction)
        let becameReady =
            !wasReady &&
            transaction.readiness?.isReadyForSourceRetirement == true
        finishIfPossible(&transaction)
        notifyPresentationReadyIfNeeded(becameReady)
    }

    func noteInteractionReady(workspaceID: UUID, surfaceID: UUID? = nil) {
        guard var transaction = active,
              transaction.targetWorkspaceID == workspaceID,
              surfaceID == nil || transaction.targetSurfaceID == surfaceID,
              var readiness = transaction.readiness else {
            return
        }
        readiness.interactionReady = true
        transaction.readiness = readiness
        workspaceSwitchSignposts.end(transaction.interactiveInterval)
        transaction.interactiveInterval = nil
        finishIfPossible(&transaction)
    }

    func noteBrowserInteractionReady(workspaceID: UUID, webView: WKWebView) {
        guard active?.targetWebViewID == ObjectIdentifier(webView) else { return }
        noteInteractionReady(workspaceID: workspaceID)
    }

    func noteInteractionNoLongerRequired() {
        guard var transaction = active,
              var readiness = transaction.readiness else {
            return
        }
        readiness.requiresInteraction = false
        transaction.readiness = readiness
        workspaceSwitchSignposts.end(transaction.interactiveInterval)
        transaction.interactiveInterval = nil
        finishIfPossible(&transaction)
    }

    func sourceWillRetire() {
        guard var transaction = active else { return }
        if transaction.portalHideInterval == nil {
            transaction.portalHideInterval = workspaceSwitchSignposts.begin(
                "ws.switch.portal-hide",
                Self.details(
                    requestID: transaction.requestID,
                    sourceWorkspaceID: transaction.sourceWorkspaceID,
                    targetWorkspaceID: transaction.targetWorkspaceID
                )
            )
        }
        active = transaction
    }

    func sourceDidRetire() {
        guard var transaction = active else { return }
        workspaceSwitchSignposts.end(transaction.portalHideInterval)
        transaction.portalHideInterval = nil
        transaction.sourceRetired = true
        finishIfPossible(&transaction)
    }

    func cancel() {
        guard var transaction = active else { return }
        releaseRendererProtection(&transaction)
        releaseFrameObservation(&transaction)
        Self.endAllIntervals(in: transaction)
        active = nil
    }

    private func reconcileTerminalTarget(
        surfaceID: UUID?,
        view: GhosttyNSView?,
        rendererPresented: Bool,
        renderedFrameSequence: UInt64,
        in transaction: inout ActiveTransaction
    ) {
        let targetViewID = view.map(ObjectIdentifier.init)
        guard transaction.targetSurfaceID != surfaceID ||
                transaction.targetTerminalViewID != targetViewID else {
            return
        }

        releaseRendererProtection(&transaction)
        releaseFrameObservation(&transaction)
        workspaceSwitchSignposts.end(transaction.rendererRealizationInterval)
        workspaceSwitchSignposts.end(transaction.firstFrameInterval)
        transaction.rendererRealizationInterval = nil
        transaction.firstFrameInterval = nil
        transaction.targetSurfaceID = nil
        transaction.targetTerminalViewID = nil
        transaction.warmFrameAvailable = false
        transaction.frameSequenceAtSelection = 0
        transaction.observedFrameAfterSelection = false

        guard let surfaceID else { return }
        installTerminalTarget(
            surfaceID: surfaceID,
            view: view,
            rendererPresented: rendererPresented,
            renderedFrameSequence: renderedFrameSequence,
            in: &transaction,
            details: Self.details(
                requestID: transaction.requestID,
                sourceWorkspaceID: transaction.sourceWorkspaceID,
                targetWorkspaceID: transaction.targetWorkspaceID,
                contentKind: .terminal
            )
        )
    }

    private func installTerminalTarget(
        surfaceID: UUID,
        view: GhosttyNSView?,
        rendererPresented: Bool,
        renderedFrameSequence: UInt64,
        in transaction: inout ActiveTransaction,
        details: String
    ) {
        transaction.targetSurfaceID = surfaceID
        transaction.targetTerminalViewID = view.map(ObjectIdentifier.init)
        transaction.warmFrameAvailable =
            rendererPresented && renderedFrameSequence > 0
        transaction.frameSequenceAtSelection = renderedFrameSequence
        beginRendererProtection(surfaceID, transaction.requestID)
        transaction.rendererProtectionActive = true

        if !rendererPresented {
            transaction.rendererRealizationInterval = workspaceSwitchSignposts.begin(
                "ws.switch.renderer-realization",
                details
            )
        }
        guard !transaction.warmFrameAvailable else { return }
        transaction.firstFrameInterval = workspaceSwitchSignposts.begin(
            "ws.switch.first-frame",
            details
        )
        guard let targetView = view else { return }
        transaction.frameObserver = notificationCenter.addObserver(
            forName: .ghosttyDidRenderFrame,
            object: targetView,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.noteFirstFrame(surfaceID: surfaceID)
            }
        }
        transaction.frameNotificationRelease =
            targetView.retainLocalRenderedFrameNotifications()
    }

    private func finishFrameObservation(_ transaction: inout ActiveTransaction) {
        workspaceSwitchSignposts.end(transaction.rendererRealizationInterval)
        transaction.rendererRealizationInterval = nil
        workspaceSwitchSignposts.end(transaction.firstFrameInterval)
        transaction.firstFrameInterval = nil
        releaseFrameObservation(&transaction)
    }

    private func releaseFrameObservation(_ transaction: inout ActiveTransaction) {
        if let frameObserver = transaction.frameObserver {
            notificationCenter.removeObserver(frameObserver)
            transaction.frameObserver = nil
        }
        transaction.frameNotificationRelease?()
        transaction.frameNotificationRelease = nil
    }

    private func finishIfPossible(_ transaction: inout ActiveTransaction) {
        guard transaction.readiness?.isReadyForSourceRetirement == true else {
            active = transaction
            return
        }
        releaseRendererProtection(&transaction)
        guard transaction.sourceRetired,
              transaction.readiness?.interactionIsReady == true else {
            active = transaction
            return
        }
        releaseFrameObservation(&transaction)
        Self.endAllIntervals(in: transaction)
        active = nil
    }

    private func releaseRendererProtection(_ transaction: inout ActiveTransaction) {
        guard transaction.rendererProtectionActive else { return }
        endRendererProtection(transaction.requestID)
        transaction.rendererProtectionActive = false
    }

    private func notifyPresentationReadyIfNeeded(_ becameReady: Bool) {
        guard becameReady else { return }
        notificationCenter.post(
            name: .workspaceSwitchPresentationDidBecomeReady,
            object: self
        )
    }

    private static func endAllIntervals(in transaction: ActiveTransaction) {
        workspaceSwitchSignposts.end(transaction.selectionCommitInterval)
        workspaceSwitchSignposts.end(transaction.portalShowInterval)
        workspaceSwitchSignposts.end(transaction.portalHideInterval)
        workspaceSwitchSignposts.end(transaction.rendererRealizationInterval)
        workspaceSwitchSignposts.end(transaction.firstFrameInterval)
        workspaceSwitchSignposts.end(transaction.interactiveInterval)
    }

    private static func details(
        requestID: UUID,
        sourceWorkspaceID: UUID,
        targetWorkspaceID: UUID,
        contentKind: ContentKind? = nil
    ) -> String {
        var details =
            "switch=\(requestID.uuidString.prefix(8)) " +
            "from=\(sourceWorkspaceID.uuidString.prefix(8)) " +
            "to=\(targetWorkspaceID.uuidString.prefix(8))"
        if let contentKind {
            details += " content=\(contentKind.rawValue)"
        }
        return details
    }
}
