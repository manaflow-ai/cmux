import AppKit
import CmuxFoundation
import CmuxTerminal

/// Completes a workspace handoff when every incoming visible terminal has
/// fresh pixels AND a revealed hosted view, so hiding the retiring
/// workspace's content can never expose a blank frame (#1291).
///
/// Pixels: each incoming surface arms a one-shot renderer frame notice
/// (`GHOSTTY_RENDERER_EVENT_UPDATE_FRAME_END` →
/// `.terminalSurfaceDidRenderFrame`). Reveal: the portal visibility flip
/// posts `.terminalPortalVisibilityDidChange`; the hosted view's hidden and
/// window state is read directly on every event.
@MainActor
final class WorkspaceHandoffFrameWatcher {
    struct Target {
        let surface: TerminalSurface
        let hostedView: NSView
    }

    private var plan: WorkspaceHandoffFramePlan?
    private var targets: [UUID: Target] = [:]
    private var observers: [NSObjectProtocol] = []
    private var hiddenObservations: [NSKeyValueObservation] = []
    private var onReady: (() -> Void)?

    /// True while incoming terminals still owe a frame or a reveal.
    /// Focus-driven handoff completions defer to this so focus arriving ahead
    /// of the first frame cannot re-expose the blank transition (#1291).
    var isPending: Bool { plan != nil }

    /// Starts watching. With no targets this never fires `onReady`; callers
    /// complete such handoffs through the immediate path instead.
    func begin(
        workspaceId: UUID,
        targets: [Target],
        onReady: @escaping () -> Void
    ) {
        cancel()
        guard !targets.isEmpty else { return }
#if DEBUG
        cmuxDebugLog(
            "ws.handoff.frameWatch.begin ws=\(workspaceId.uuidString.prefix(5)) expected=\(targets.count)"
        )
#endif
        self.targets = Dictionary(
            targets.map { ($0.surface.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        plan = WorkspaceHandoffFramePlan(
            workspaceId: workspaceId,
            expectedSurfaceIds: Set(self.targets.keys)
        )
        self.onReady = onReady
        for target in self.targets.values {
            target.surface.armRendererFrameNotice()
        }
        observers.append(NotificationCenter.default.addObserver(
            forName: .terminalSurfaceDidRenderFrame,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            self?.handleRenderedFrame(notification)
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: .terminalPortalVisibilityDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.completeIfReady()
        })
        // The portal reveal path can unhide a hosted view without posting a
        // visibility notification; observe the hidden bit directly.
        for target in self.targets.values {
            hiddenObservations.append(target.hostedView.observe(
                \.isHidden, options: [.new]
            ) { [weak self] _, _ in
                Task { @MainActor [weak self] in
                    self?.completeIfReady()
                }
            })
        }
    }

    func cancel() {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers = []
        hiddenObservations.forEach { $0.invalidate() }
        hiddenObservations = []
        for target in targets.values {
            target.surface.cancelRendererFrameNotice()
        }
        targets = [:]
        plan = nil
        onReady = nil
    }

    private func handleRenderedFrame(_ notification: Notification) {
        guard let plan,
              let surfaceId = notification
                  .userInfo?[TerminalSurfaceRenderNotice.surfaceIdKey] as? UUID else { return }
        var updated = plan
        updated.recordFrame(workspaceId: plan.workspaceId, surfaceId: surfaceId)
        self.plan = updated
#if DEBUG
        cmuxDebugLog(
            "ws.handoff.frameWatch.frame surface=\(surfaceId.uuidString.prefix(5)) remaining=\(updated.pendingSurfaceIds.count)"
        )
#endif
        completeIfReady()
    }

    private func completeIfReady() {
        guard let plan, plan.isComplete else { return }
        for target in targets.values {
            let view = target.hostedView
            guard !view.isHidden, view.window != nil else { return }
        }
        let ready = onReady
        cancel()
        // One main-queue turn so the frame's layer-contents commit (also
        // queued to main) lands before the retiring content is hidden.
        DispatchQueue.main.async { ready?() }
    }
}
