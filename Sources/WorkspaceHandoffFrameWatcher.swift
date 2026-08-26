import AppKit
import CmuxTerminal

/// Completes a workspace handoff when every incoming visible terminal is
/// presentable, so hiding the retiring workspace's content can never expose a
/// blank frame (#1291).
///
/// Presentable means the hosted view is revealed (unhidden, in a window) and
/// the terminal layer holds pixels (`layer.contents != nil`). A warm surface
/// keeps its last IOSurface across hides, so it is presentable the moment the
/// portal reveals it; a surface whose renderer was reclaimed becomes
/// presentable when the rebuilt renderer publishes its first IOSurface. Both
/// transitions are observed (portal visibility notification, `isHidden` and
/// `contents` KVO); the caller's timeout stays the liveness backstop.
@MainActor
final class WorkspaceHandoffFrameWatcher {
    struct Target {
        let surface: TerminalSurface
        let hostedView: GhosttySurfaceScrollView
    }

    private var targets: [Target] = []
    private var observers: [NSObjectProtocol] = []
    private var kvoObservations: [NSKeyValueObservation] = []
    private var onReady: (() -> Void)?
    private var workspaceId: UUID?

    /// True while incoming terminals are not yet presentable. Focus-driven
    /// handoff completions defer to this so focus arriving ahead of pixels
    /// cannot re-expose the blank transition (#1291).
    var isPending: Bool { onReady != nil }

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
        self.workspaceId = workspaceId
        self.targets = targets
        self.onReady = onReady

        observers.append(NotificationCenter.default.addObserver(
            forName: .terminalPortalVisibilityDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.completeIfReady()
        })
        for target in targets {
            // The portal reveal path can unhide a hosted view without posting
            // a visibility notification; observe the hidden bit directly.
            kvoObservations.append(target.hostedView.observe(
                \.isHidden, options: [.new]
            ) { [weak self] _, _ in
                Task { @MainActor [weak self] in
                    self?.completeIfReady()
                }
            })
            // A reclaimed renderer publishes its first IOSurface by setting
            // the terminal layer's contents; observe that for cold reveals.
            if let layer = target.hostedView.surfaceView.layer {
                kvoObservations.append(layer.observe(
                    \.contents, options: [.new]
                ) { [weak self] _, _ in
                    Task { @MainActor [weak self] in
                        self?.completeIfReady()
                    }
                })
            }
        }
        // The reveal may already be complete (cycle-hot warm pair).
        completeIfReady()
    }

    func cancel() {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers = []
        kvoObservations.forEach { $0.invalidate() }
        kvoObservations = []
        targets = []
        onReady = nil
        workspaceId = nil
    }

    private func isPresentable(_ target: Target) -> Bool {
        let view = target.hostedView
        guard !view.isHidden, view.window != nil else { return false }
        return view.surfaceView.layer?.contents != nil
    }

    private func completeIfReady() {
        guard onReady != nil else { return }
        guard targets.allSatisfy(isPresentable) else { return }
#if DEBUG
        cmuxDebugLog(
            "ws.handoff.frameWatch.presentable ws=\(workspaceId?.uuidString.prefix(5) ?? "nil") targets=\(targets.count)"
        )
#endif
        let ready = onReady
        cancel()
        // One main-queue turn so any contents commit queued behind this event
        // lands before the retiring content is hidden.
        DispatchQueue.main.async { ready?() }
    }
}
