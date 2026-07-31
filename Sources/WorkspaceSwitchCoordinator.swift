import AppKit
import Foundation
import WebKit

enum WorkspaceSwitchProfilingSignposts {
    private static let signposts = DynamicTracingSignposts(
        subsystem: "com.cmux.workspace-switch"
    )

    @inline(__always)
    static func begin(
        _ name: StaticString,
        _ message: @autoclosure () -> String
    ) -> DynamicTracingSignpostInterval? {
        signposts.begin(name, message())
    }

    @inline(__always)
    static func end(_ interval: DynamicTracingSignpostInterval?) {
        signposts.end(interval)
    }
}

/// Owns one window's workspace-switch transaction from selection commit through
/// presentation and input readiness. `ContentView` supplies the AppKit/Ghostty
/// signals because it owns the mounted presentation; `TabManager` owns this
/// coordinator so rapid selection changes have one place to cancel stale work.
@MainActor
final class WorkspaceSwitchCoordinator {
    enum ContentKind: String, Equatable {
        case terminal
        case browser
        case passive
    }

    struct Readiness: Equatable {
        let contentKind: ContentKind
        let requiresInteraction: Bool
        var nativeSurfaceLoaded: Bool
        var portalPresented: Bool
        var firstFramePresented: Bool
        var interactionReady: Bool

        var isReadyForSourceRetirement: Bool {
            actualPresentationIsReady
        }

        var actualPresentationIsReady: Bool {
            let inputIsReady = !requiresInteraction || interactionReady
            switch contentKind {
            case .terminal:
                return portalPresented && firstFramePresented && inputIsReady
            case .browser:
                return portalPresented && inputIsReady
            case .passive:
                return true
            }
        }
    }

    struct PresentationTarget {
        let workspaceID: UUID
        let contentKind: ContentKind
        let terminalSurfaceID: UUID?
        let terminalView: GhosttyNSView?
        let browserWebView: WKWebView?
        let nativeSurfaceLoaded: Bool
        let rendererPresented: Bool
        let portalPresented: Bool
        let firstFramePresented: Bool
        let interactionReady: Bool
        let requiresInteraction: Bool
    }

    private struct ActiveTransaction {
        let requestID: UUID
        let sourceWorkspaceID: UUID
        let targetWorkspaceID: UUID
        var targetSurfaceID: UUID?
        var targetWebViewID: ObjectIdentifier?
        var readiness: Readiness?
        var sourceRetired = false
        var rendererProtectionActive: Bool
        var frameNotificationRelease: (() -> Void)?
        var selectionCommitInterval: DynamicTracingSignpostInterval?
        var portalShowInterval: DynamicTracingSignpostInterval?
        var portalHideInterval: DynamicTracingSignpostInterval?
        var rendererRealizationInterval: DynamicTracingSignpostInterval?
        var firstFrameInterval: DynamicTracingSignpostInterval?
        var interactiveInterval: DynamicTracingSignpostInterval?
    }

    private var active: ActiveTransaction?

    var readinessForTesting: Readiness? {
        active?.readiness
    }

    var isReadyForSourceRetirement: Bool {
        active?.readiness?.isReadyForSourceRetirement == true
    }

    func selectionWillCommit(
        from sourceWorkspaceID: UUID?,
        to targetWorkspaceID: UUID?,
        targetSurfaceID: UUID?
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
        let selectionCommitInterval = WorkspaceSwitchProfilingSignposts.begin(
            "ws.switch.selection-commit",
            details
        )
        let interactiveInterval = WorkspaceSwitchProfilingSignposts.begin(
            "ws.switch.interactive",
            details
        )

        if let targetSurfaceID {
            RendererRealizationController.shared.beginWorkspaceSwitchPresentationProtection(
                surfaceID: targetSurfaceID,
                requestID: requestID
            )
        }
        active = ActiveTransaction(
            requestID: requestID,
            sourceWorkspaceID: sourceWorkspaceID,
            targetWorkspaceID: targetWorkspaceID,
            targetSurfaceID: targetSurfaceID,
            rendererProtectionActive: targetSurfaceID != nil,
            selectionCommitInterval: selectionCommitInterval,
            interactiveInterval: interactiveInterval
        )
    }

    func selectionDidCommit(from sourceWorkspaceID: UUID?, to targetWorkspaceID: UUID?) {
        guard var transaction = active,
              transaction.sourceWorkspaceID == sourceWorkspaceID,
              transaction.targetWorkspaceID == targetWorkspaceID else {
            return
        }
        WorkspaceSwitchProfilingSignposts.end(transaction.selectionCommitInterval)
        transaction.selectionCommitInterval = nil
        active = transaction
    }

    func beginPresentation(_ target: PresentationTarget) {
        guard var transaction = active,
              transaction.targetWorkspaceID == target.workspaceID else {
            return
        }

        if transaction.targetSurfaceID != target.terminalSurfaceID {
            releaseRendererProtection(&transaction)
            transaction.targetSurfaceID = target.terminalSurfaceID
            if let targetSurfaceID = target.terminalSurfaceID {
                RendererRealizationController.shared.beginWorkspaceSwitchPresentationProtection(
                    surfaceID: targetSurfaceID,
                    requestID: transaction.requestID
                )
                transaction.rendererProtectionActive = true
            }
        }
        transaction.targetWebViewID = target.browserWebView.map(ObjectIdentifier.init)
        transaction.readiness = Readiness(
            contentKind: target.contentKind,
            requiresInteraction: target.requiresInteraction,
            nativeSurfaceLoaded: target.nativeSurfaceLoaded,
            portalPresented: target.portalPresented,
            firstFramePresented: target.firstFramePresented,
            interactionReady: target.interactionReady
        )

        let details = Self.details(
            requestID: transaction.requestID,
            sourceWorkspaceID: transaction.sourceWorkspaceID,
            targetWorkspaceID: transaction.targetWorkspaceID,
            contentKind: target.contentKind
        )
        if !target.portalPresented {
            transaction.portalShowInterval = WorkspaceSwitchProfilingSignposts.begin(
                "ws.switch.portal-show",
                details
            )
        }
        if target.contentKind == .terminal, !target.rendererPresented {
            transaction.rendererRealizationInterval = WorkspaceSwitchProfilingSignposts.begin(
                "ws.switch.renderer-realization",
                details
            )
        }
        if target.contentKind == .terminal, !target.firstFramePresented {
            transaction.firstFrameInterval = WorkspaceSwitchProfilingSignposts.begin(
                "ws.switch.first-frame",
                details
            )
            transaction.frameNotificationRelease =
                target.terminalView?.retainLocalRenderedFrameNotifications()
        }
        if target.portalPresented {
            releaseRendererProtection(&transaction)
        }
        if target.rendererPresented {
            WorkspaceSwitchProfilingSignposts.end(transaction.rendererRealizationInterval)
            transaction.rendererRealizationInterval = nil
        }
        if target.firstFramePresented {
            WorkspaceSwitchProfilingSignposts.end(transaction.firstFrameInterval)
            transaction.firstFrameInterval = nil
        }
        if target.interactionReady || !target.requiresInteraction {
            WorkspaceSwitchProfilingSignposts.end(transaction.interactiveInterval)
            transaction.interactiveInterval = nil
        }
        finishIfPossible(&transaction)
    }

    func noteTerminalPortalPresented(surfaceID: UUID) {
        guard var transaction = active,
              transaction.targetSurfaceID == surfaceID,
              var readiness = transaction.readiness else {
            return
        }
        readiness.portalPresented = true
        transaction.readiness = readiness
        WorkspaceSwitchProfilingSignposts.end(transaction.portalShowInterval)
        transaction.portalShowInterval = nil
        releaseRendererProtection(&transaction)
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
        WorkspaceSwitchProfilingSignposts.end(transaction.portalShowInterval)
        transaction.portalShowInterval = nil
        finishIfPossible(&transaction)
    }

    func noteFirstFrame(surfaceID: UUID) {
        guard var transaction = active,
              transaction.targetSurfaceID == surfaceID,
              var readiness = transaction.readiness,
              readiness.portalPresented else {
            return
        }
        readiness.firstFramePresented = true
        transaction.readiness = readiness
        WorkspaceSwitchProfilingSignposts.end(transaction.rendererRealizationInterval)
        transaction.rendererRealizationInterval = nil
        WorkspaceSwitchProfilingSignposts.end(transaction.firstFrameInterval)
        transaction.firstFrameInterval = nil
        transaction.frameNotificationRelease?()
        transaction.frameNotificationRelease = nil
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
        WorkspaceSwitchProfilingSignposts.end(transaction.interactiveInterval)
        transaction.interactiveInterval = nil
        finishIfPossible(&transaction)
    }

    func noteBrowserInteractionReady(workspaceID: UUID, webView: WKWebView) {
        guard active?.targetWebViewID == ObjectIdentifier(webView) else { return }
        noteInteractionReady(workspaceID: workspaceID)
    }

    func sourceWillRetire() {
        guard var transaction = active else { return }
        transaction.portalHideInterval = WorkspaceSwitchProfilingSignposts.begin(
            "ws.switch.portal-hide",
            Self.details(
                requestID: transaction.requestID,
                sourceWorkspaceID: transaction.sourceWorkspaceID,
                targetWorkspaceID: transaction.targetWorkspaceID
            )
        )
        active = transaction
    }

    func sourceDidRetire() {
        guard var transaction = active else { return }
        WorkspaceSwitchProfilingSignposts.end(transaction.portalHideInterval)
        transaction.portalHideInterval = nil
        transaction.sourceRetired = true
        finishIfPossible(&transaction)
    }

    func cancel() {
        guard var transaction = active else { return }
        releaseRendererProtection(&transaction)
        transaction.frameNotificationRelease?()
        Self.endAllIntervals(in: transaction)
        active = nil
    }

    private func finishIfPossible(_ transaction: inout ActiveTransaction) {
        guard transaction.readiness?.actualPresentationIsReady == true else {
            active = transaction
            return
        }
        transaction.frameNotificationRelease?()
        transaction.frameNotificationRelease = nil
        releaseRendererProtection(&transaction)
        guard transaction.sourceRetired else {
            active = transaction
            return
        }
        Self.endAllIntervals(in: transaction)
        active = nil
    }

    private func releaseRendererProtection(_ transaction: inout ActiveTransaction) {
        guard transaction.rendererProtectionActive else { return }
        RendererRealizationController.shared.endWorkspaceSwitchPresentationProtection(
            requestID: transaction.requestID
        )
        transaction.rendererProtectionActive = false
    }

    private static func endAllIntervals(in transaction: ActiveTransaction) {
        WorkspaceSwitchProfilingSignposts.end(transaction.selectionCommitInterval)
        WorkspaceSwitchProfilingSignposts.end(transaction.portalShowInterval)
        WorkspaceSwitchProfilingSignposts.end(transaction.portalHideInterval)
        WorkspaceSwitchProfilingSignposts.end(transaction.rendererRealizationInterval)
        WorkspaceSwitchProfilingSignposts.end(transaction.firstFrameInterval)
        WorkspaceSwitchProfilingSignposts.end(transaction.interactiveInterval)
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
