import AppKit
import Foundation
import WebKit

extension Notification.Name {
    static let terminalPortalDidBecomePresentable = Notification.Name("cmux.terminalPortalDidBecomePresentable")
}

/// Records one window's selection, presentation, and input-readiness intervals.
/// Mount reconciliation remains authoritative; these diagnostic milestones
/// never delay source retirement. The target frame observer is installed before
/// selection mutates the mounted tree.
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
        /// Visual presentation readiness is diagnostic only. Mount reconciliation
        /// owns source retirement, so a missed frame or portal signal cannot
        /// strand the previous workspace in the live view graph.
        var presentationIsReady: Bool {
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
        var sourceWorkspaceID: UUID
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
    private let beginRendererProtection: @MainActor (UUID, UUID, @escaping () -> Bool) -> Void
    private let endRendererProtection: @MainActor (UUID) -> Void
    private var active: ActiveTransaction?
    init(
        notificationCenter: NotificationCenter = .default,
        beginRendererProtection:
            @escaping @MainActor (UUID, UUID, @escaping () -> Bool) -> Void = {
            surfaceID, requestID, ownerIsAlive in
            RendererRealizationController.shared.beginWorkspaceSwitchPresentationProtection(
                surfaceID: surfaceID,
                requestID: requestID,
                ownerIsAlive: ownerIsAlive
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

    /// The current destination's visual diagnostic state.
    ///
    /// This value never gates selection or mount ownership.
    var isPresentationReady: Bool {
        guard let active else { return true }
        return active.readiness?.presentationIsReady == true
    }

    @discardableResult
    func selectionWillCommit(
        from sourceWorkspaceID: UUID?,
        to targetWorkspaceID: UUID?,
        targetSurfaceID: UUID?,
        targetTerminalView: GhosttyNSView?,
        targetRendererPresented: Bool,
        targetRenderedFrameSequence: UInt64
    ) -> UUID? {
        guard sourceWorkspaceID != targetWorkspaceID else { return nil }
        cancel()
        guard let sourceWorkspaceID, let targetWorkspaceID else { return nil }

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
        return requestID
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

    func beginPresentation(
        _ target: PresentationTarget,
        retiringWorkspaceID: UUID
    ) {
        guard var transaction = active else { return }
        guard transaction.targetWorkspaceID == target.workspaceID else {
            cancel()
            return
        }

        // SwiftUI can coalesce rapid model selections. The mounted source is
        // therefore the last selection this view actually reconciled, not
        // necessarily the model value immediately preceding the target.
        transaction.sourceWorkspaceID = retiringWorkspaceID
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
        if renderedFrameSequence > transaction.frameSequenceAtSelection {
            transaction.observedFrameAfterSelection = true
            readiness.firstFramePresented = true
            finishFrameObservation(&transaction)
        }
        readiness.portalPresented = true
        transaction.readiness = readiness
        workspaceSwitchSignposts.end(transaction.portalShowInterval)
        transaction.portalShowInterval = nil
        finishIfPossible(&transaction)
    }

    func noteBrowserPortalPresented(webView: WKWebView) {
        guard var transaction = active,
              transaction.targetWebViewID == ObjectIdentifier(webView),
              var readiness = transaction.readiness else {
            return
        }
        readiness.portalPresented = true
        transaction.readiness = readiness
        workspaceSwitchSignposts.end(transaction.portalShowInterval)
        transaction.portalShowInterval = nil
        finishIfPossible(&transaction)
    }

    func noteFirstFrame(surfaceID: UUID, requestID: UUID) {
        guard var transaction = active,
              transaction.requestID == requestID,
              transaction.targetSurfaceID == surfaceID else {
            return
        }
        transaction.observedFrameAfterSelection = true
        if var readiness = transaction.readiness {
            readiness.firstFramePresented = true
            transaction.readiness = readiness
        }
        finishFrameObservation(&transaction)
        finishIfPossible(&transaction)
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

    func sourceWillRetire(workspaceID: UUID) {
        guard var transaction = active,
              transaction.sourceWorkspaceID == workspaceID else {
            return
        }
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

    func sourceDidRetire(workspaceID: UUID) {
        guard var transaction = active,
              transaction.sourceWorkspaceID == workspaceID else {
            return
        }
        workspaceSwitchSignposts.end(transaction.portalHideInterval)
        transaction.portalHideInterval = nil
        transaction.sourceRetired = true
        // Once mount reconciliation has made the destination authoritative,
        // normal portal visibility owns renderer reclamation again. Visual
        // diagnostics may continue without extending the switch-path lease.
        releaseRendererProtection(&transaction)
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
        beginRendererProtection(surfaceID, transaction.requestID) {
            [weak self] in self != nil
        }
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
        let requestID = transaction.requestID
        transaction.frameObserver = notificationCenter.addObserver(
            forName: .ghosttyDidRenderFrame,
            object: targetView,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.noteFirstFrame(surfaceID: surfaceID, requestID: requestID)
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
        guard transaction.sourceRetired,
              transaction.readiness?.presentationIsReady == true,
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
