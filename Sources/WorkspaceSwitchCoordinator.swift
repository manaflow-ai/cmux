import AppKit
import Foundation
import WebKit

extension Notification.Name {
    static let terminalPortalDidBecomePresentable = Notification.Name("cmux.terminalPortalDidBecomePresentable")
    static let browserPortalDidBecomePresentable = Notification.Name("cmux.browserPortalDidBecomePresentable")
}

/// Records one window's selection, presentation, and input-readiness intervals.
/// Mount reconciliation remains authoritative; these diagnostic milestones
/// never delay source retirement. The target frame observer is installed before
/// selection mutates the mounted tree.
@MainActor
final class WorkspaceSwitchCoordinator {
    private let signposts: WorkspaceSwitchSignposts
    private let notificationCenter: NotificationCenter
    private let beginRendererProtection: @MainActor (UUID, UUID, @escaping () -> Bool) -> Void
    private let endRendererProtection: @MainActor (UUID) -> Void
    private var active: WorkspaceSwitchActiveTransaction?
    private var reconciledWorkspaceID: UUID?
    init(
        signposts: WorkspaceSwitchSignposts = WorkspaceSwitchSignposts(),
        notificationCenter: NotificationCenter = .default,
        beginRendererProtection: @escaping @MainActor (UUID, UUID, @escaping () -> Bool) -> Void = { surfaceID, requestID, ownerIsAlive in
            RendererRealizationController.shared.beginWorkspaceSwitchPresentationProtection(
                surfaceID: surfaceID,
                requestID: requestID,
                ownerIsAlive: ownerIsAlive
            )
        },
        endRendererProtection: @escaping @MainActor (UUID) -> Void = { requestID in
            RendererRealizationController.shared.endWorkspaceSwitchPresentationProtection(requestID: requestID)
        }
    ) {
        self.signposts = signposts
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

    var isMeasuringSwitch: Bool { active != nil }

    func selectionDidReconcile(workspaceID: UUID?) { reconciledWorkspaceID = workspaceID }

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
        guard targetWorkspaceID != reconciledWorkspaceID else { return nil }
        guard let sourceWorkspaceID, let targetWorkspaceID else { return nil }

        let requestID = UUID()
        var transaction = WorkspaceSwitchActiveTransaction(
            requestID: requestID,
            sourceWorkspaceID: sourceWorkspaceID,
            targetWorkspaceID: targetWorkspaceID,
            selectionCommitInterval: signposts.begin(
                "ws.switch.selection-commit",
                Self.details(
                    requestID: requestID,
                    sourceWorkspaceID: sourceWorkspaceID,
                    targetWorkspaceID: targetWorkspaceID
                )
            ),
            interactiveInterval: signposts.begin(
                "ws.switch.interactive",
                Self.details(
                    requestID: requestID,
                    sourceWorkspaceID: sourceWorkspaceID,
                    targetWorkspaceID: targetWorkspaceID
                )
            )
        )
        if let targetSurfaceID {
            installTerminalTarget(
                surfaceID: targetSurfaceID,
                view: targetTerminalView,
                rendererPresented: targetRendererPresented,
                renderedFrameSequence: targetRenderedFrameSequence,
                in: &transaction
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
        signposts.end(transaction.selectionCommitInterval)
        transaction.selectionCommitInterval = nil
        active = transaction
    }

    func beginPresentation(
        _ target: WorkspaceSwitchPresentationTarget,
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
        transaction.readiness = WorkspaceSwitchReadiness(
            contentKind: target.contentKind,
            requiresInteraction: target.requiresInteraction,
            portalPresented: target.portalPresented,
            firstFramePresented: firstFramePresented,
            interactionReady: target.interactionReady
        )

        if !target.portalPresented {
            transaction.portalShowInterval = signposts.begin(
                "ws.switch.portal-show",
                Self.details(
                    requestID: transaction.requestID,
                    sourceWorkspaceID: transaction.sourceWorkspaceID,
                    targetWorkspaceID: transaction.targetWorkspaceID,
                    contentKind: target.contentKind
                )
            )
        }
        if firstFramePresented {
            finishFrameObservation(&transaction)
        }
        if target.interactionReady || !target.requiresInteraction {
            signposts.end(transaction.interactiveInterval)
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
        signposts.end(transaction.portalShowInterval)
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
        signposts.end(transaction.portalShowInterval)
        transaction.portalShowInterval = nil
        finishIfPossible(&transaction)
    }

    func noteFirstFrame(
        surfaceID: UUID,
        requestID: UUID,
        renderedFrameSequence: UInt64
    ) {
        guard var transaction = active,
              transaction.requestID == requestID,
              transaction.targetSurfaceID == surfaceID,
              renderedFrameSequence > transaction.frameSequenceAtSelection else {
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

    /// Ends interaction measurement when any control in the destination
    /// workspace becomes ready. The focused pane can legitimately change while
    /// SwiftUI reconciles, so a surface captured before selection is not an
    /// authoritative interaction boundary.
    func noteInteractionReady(workspaceID: UUID) {
        guard var transaction = active,
              transaction.targetWorkspaceID == workspaceID,
              var readiness = transaction.readiness else {
            return
        }
        readiness.interactionReady = true
        transaction.readiness = readiness
        signposts.end(transaction.interactiveInterval)
        transaction.interactiveInterval = nil
        finishIfPossible(&transaction)
    }

    func noteBrowserInteractionReady(workspaceID: UUID, webView _: WKWebView) {
        guard active?.targetWorkspaceID == workspaceID else { return }
        noteInteractionReady(workspaceID: workspaceID)
    }

    func noteInteractionNoLongerRequired() {
        guard var transaction = active,
              var readiness = transaction.readiness else {
            return
        }
        readiness.requiresInteraction = false
        transaction.readiness = readiness
        signposts.end(transaction.interactiveInterval)
        transaction.interactiveInterval = nil
        finishIfPossible(&transaction)
    }

    func sourceWillRetire(workspaceID: UUID) {
        guard var transaction = active,
              transaction.sourceWorkspaceID == workspaceID else {
            return
        }
        if transaction.portalHideInterval == nil {
            transaction.portalHideInterval = signposts.begin(
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
        signposts.end(transaction.portalHideInterval)
        transaction.portalHideInterval = nil
        transaction.sourceRetired = true
        // Source retirement is the authoritative end of the mount handoff.
        // A cold destination may never produce a drawable frame, so do not
        // keep its observer or local render-demand lease alive for the rest of
        // the window. The remaining intervals are diagnostic only.
        finishFrameObservation(&transaction)
        // Once mount reconciliation has made the destination authoritative,
        // normal portal visibility owns renderer reclamation again. Visual
        // diagnostics may continue without extending the switch-path lease.
        releaseRendererProtection(&transaction)
        guard transaction.readiness?.presentationIsReady == true else {
            // Mount reconciliation has completed, so an unresolved visual
            // signal is diagnostic-only. End the transaction here rather than
            // leaving an active signpost/interaction state waiting for a frame
            // whose observer was deliberately released above.
            endAllIntervals(in: transaction)
            active = nil
            return
        }
        finishIfPossible(&transaction)
    }

    func cancel() {
        guard var transaction = active else { return }
        releaseRendererProtection(&transaction)
        releaseFrameObservation(&transaction)
        endAllIntervals(in: transaction)
        active = nil
    }

    private func reconcileTerminalTarget(
        surfaceID: UUID?,
        view: GhosttyNSView?,
        rendererPresented: Bool,
        renderedFrameSequence: UInt64,
        in transaction: inout WorkspaceSwitchActiveTransaction
    ) {
        let targetViewID = view.map(ObjectIdentifier.init)
        guard transaction.targetSurfaceID != surfaceID ||
                transaction.targetTerminalViewID != targetViewID else {
            return
        }

        releaseRendererProtection(&transaction)
        releaseFrameObservation(&transaction)
        signposts.end(transaction.rendererRealizationInterval)
        signposts.end(transaction.firstFrameInterval)
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
            in: &transaction
        )
    }

    private func installTerminalTarget(
        surfaceID: UUID,
        view: GhosttyNSView?,
        rendererPresented: Bool,
        renderedFrameSequence: UInt64,
        in transaction: inout WorkspaceSwitchActiveTransaction
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
            transaction.rendererRealizationInterval = signposts.begin(
                "ws.switch.renderer-realization",
                Self.details(
                    requestID: transaction.requestID,
                    sourceWorkspaceID: transaction.sourceWorkspaceID,
                    targetWorkspaceID: transaction.targetWorkspaceID,
                    contentKind: .terminal
                )
            )
        }
        guard !transaction.warmFrameAvailable else { return }
        transaction.firstFrameInterval = signposts.begin(
            "ws.switch.first-frame",
            Self.details(
                requestID: transaction.requestID,
                sourceWorkspaceID: transaction.sourceWorkspaceID,
                targetWorkspaceID: transaction.targetWorkspaceID,
                contentKind: .terminal
            )
        )
        guard let targetView = view else { return }
        let requestID = transaction.requestID
        let observer = notificationCenter.addObserver(
            forName: .ghosttyDidRenderFrame,
            object: targetView,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.noteFirstFrame(
                    surfaceID: surfaceID,
                    requestID: requestID,
                    renderedFrameSequence: targetView.renderedFrameSequence
                )
            }
        }
        transaction.frameObservation = WorkspaceSwitchFrameObservation(
            notificationCenter: notificationCenter,
            observer: observer,
            releaseRenderedFrameNotifications:
                targetView.retainLocalRenderedFrameNotifications()
        )
    }

    private func finishFrameObservation(_ transaction: inout WorkspaceSwitchActiveTransaction) {
        signposts.end(transaction.rendererRealizationInterval)
        transaction.rendererRealizationInterval = nil
        signposts.end(transaction.firstFrameInterval)
        transaction.firstFrameInterval = nil
        releaseFrameObservation(&transaction)
    }

    private func releaseFrameObservation(_ transaction: inout WorkspaceSwitchActiveTransaction) {
        transaction.frameObservation = nil
    }

    private func finishIfPossible(_ transaction: inout WorkspaceSwitchActiveTransaction) {
        guard transaction.sourceRetired,
              transaction.readiness?.presentationIsReady == true,
              transaction.readiness?.interactionIsReady == true else {
            active = transaction
            return
        }
        releaseFrameObservation(&transaction)
        endAllIntervals(in: transaction)
        active = nil
    }

    private func releaseRendererProtection(_ transaction: inout WorkspaceSwitchActiveTransaction) {
        guard transaction.rendererProtectionActive else { return }
        endRendererProtection(transaction.requestID)
        transaction.rendererProtectionActive = false
    }

    private func endAllIntervals(in transaction: WorkspaceSwitchActiveTransaction) {
        signposts.end(transaction.selectionCommitInterval)
        signposts.end(transaction.portalShowInterval)
        signposts.end(transaction.portalHideInterval)
        signposts.end(transaction.rendererRealizationInterval)
        signposts.end(transaction.firstFrameInterval)
        signposts.end(transaction.interactiveInterval)
    }

    private static func details(
        requestID: UUID,
        sourceWorkspaceID: UUID,
        targetWorkspaceID: UUID,
        contentKind: WorkspaceSwitchContentKind? = nil
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
