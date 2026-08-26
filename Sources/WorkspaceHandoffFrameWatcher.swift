import AppKit
import CmuxFoundation
import CmuxTerminal

/// Waits for the incoming workspace's visible terminals to render their first
/// frames after a workspace switch, then fires a ready action. While waiting
/// it retains rendered-frame notification demand so the renderer publishes
/// `.ghosttyDidRenderFrame` for each surface. The handoff keeps the retiring
/// workspace's content visible until then (manaflow-ai/cmux#1291).
@MainActor
final class WorkspaceHandoffFrameWatcher {
    private var plan: WorkspaceHandoffFramePlan?
    private var observer: NSObjectProtocol?
    private var frameDemandRetention: (any RenderDemandRetention)?
    private var onReady: (() -> Void)?

    /// Starts watching. An empty `expectedSurfaceIds` never fires `onReady`;
    /// callers complete such handoffs through the immediate path instead.
    func begin(
        workspaceId: UUID,
        expectedSurfaceIds: Set<UUID>,
        onReady: @escaping () -> Void
    ) {
        cancel()
        guard !expectedSurfaceIds.isEmpty else { return }
        plan = WorkspaceHandoffFramePlan(
            workspaceId: workspaceId,
            expectedSurfaceIds: expectedSurfaceIds
        )
        self.onReady = onReady
        frameDemandRetention = GhosttyApp.renderedFrameNotificationDemand.retain()
        observer = NotificationCenter.default.addObserver(
            forName: .ghosttyDidRenderFrame,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            self?.handleRenderedFrame(notification)
        }
    }

    func cancel() {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
            self.observer = nil
        }
        frameDemandRetention?.release()
        frameDemandRetention = nil
        plan = nil
        onReady = nil
    }

    private func handleRenderedFrame(_ notification: Notification) {
        guard plan != nil,
              let view = notification.object as? GhosttyNSView,
              let workspaceId = view.tabId,
              let surfaceId = view.terminalSurface?.id else { return }
        guard plan?.recordFrame(workspaceId: workspaceId, surfaceId: surfaceId) == true else { return }
        let ready = onReady
        cancel()
        ready?()
    }
}
