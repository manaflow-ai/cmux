import Foundation
import CmuxTerminal
import os

private final class GhosttyCurrentDirectoryAction: @unchecked Sendable {
    let directory: String
    let authoritativeGeometry: NotificationScrollRestoreGeometry?
    let isReplayBoundary: Bool
    weak var surfaceView: GhosttyNSView?
    weak var terminalSurface: TerminalSurface?

    init(
        directory: String,
        authoritativeGeometry: NotificationScrollRestoreGeometry?,
        isReplayBoundary: Bool,
        surfaceView: GhosttyNSView,
        terminalSurface: TerminalSurface?
    ) {
        self.directory = directory
        self.authoritativeGeometry = authoritativeGeometry
        self.isReplayBoundary = isReplayBoundary
        self.surfaceView = surfaceView
        self.terminalSurface = terminalSurface
    }
}

private final class GhosttyCurrentDirectoryActionDispatcher: @unchecked Sendable {
    private final class BoundaryRegistration {
        weak var surfaceView: GhosttyNSView?
        var remainingValues: Set<String>

        init(surfaceView: GhosttyNSView, values: Set<String>) {
            self.surfaceView = surfaceView
            self.remainingValues = values
        }
    }

    private struct State {
        var pendingBySurface: [ObjectIdentifier: [GhosttyCurrentDirectoryAction]] = [:]
        var boundaryRegistrations: [ObjectIdentifier: BoundaryRegistration] = [:]
    }

    static let shared = GhosttyCurrentDirectoryActionDispatcher()

    private let state = OSAllocatedUnfairLock(initialState: State())
    private let wakeContinuation: AsyncStream<Void>.Continuation

    private init() {
        let (wakeStream, wakeContinuation) = AsyncStream<Void>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        self.wakeContinuation = wakeContinuation
        Task { @MainActor [weak self] in
            for await _ in wakeStream {
                guard let self else { return }
                while true {
                    let batch = self.takePendingBatch()
                    guard !batch.isEmpty else { break }
                    for action in batch {
                        Self.deliver(action)
                    }
                    await Task.yield()
                }
            }
        }
    }

    func registerReplayBoundaries(
        for surfaceView: GhosttyNSView,
        startBoundary: String,
        endBoundary: String
    ) {
        let key = ObjectIdentifier(surfaceView)
        state.withLock { state in
            state.boundaryRegistrations[key] = BoundaryRegistration(
                surfaceView: surfaceView,
                values: [startBoundary, endBoundary]
            )
        }
    }

    func enqueue(
        directory: String,
        authoritativeGeometry: NotificationScrollRestoreGeometry?,
        surfaceView: GhosttyNSView,
        terminalSurface: TerminalSurface?
    ) {
        let key = ObjectIdentifier(surfaceView)
        state.withLock { state in
            let registration = state.boundaryRegistrations[key]
            let isCurrentRegistration = registration?.surfaceView === surfaceView
            let isReplayBoundary = isCurrentRegistration
                && registration?.remainingValues.remove(directory) != nil
            if registration?.remainingValues.isEmpty == true || !isCurrentRegistration {
                state.boundaryRegistrations.removeValue(forKey: key)
            }
            let action = GhosttyCurrentDirectoryAction(
                directory: directory,
                authoritativeGeometry: authoritativeGeometry,
                isReplayBoundary: isReplayBoundary,
                surfaceView: surfaceView,
                terminalSurface: terminalSurface
            )
            var pending = state.pendingBySurface.removeValue(forKey: key) ?? []
            if !isReplayBoundary, pending.last?.isReplayBoundary == false {
                pending[pending.count - 1] = action
            } else {
                pending.append(action)
            }
            state.pendingBySurface[key] = pending
        }
        wakeContinuation.yield()
    }

    private func takePendingBatch() -> [GhosttyCurrentDirectoryAction] {
        state.withLock { state in
            let batch = state.pendingBySurface.values.flatMap { $0 }
            state.pendingBySurface.removeAll(keepingCapacity: true)
            return batch
        }
    }

    @MainActor
    private static func deliver(_ action: GhosttyCurrentDirectoryAction) {
        guard let surfaceView = action.surfaceView else { return }
        if action.terminalSurface?.hostedView.sessionScrollbackReplayDidReceiveBoundary(
            action.directory,
            authoritativeGeometry: action.authoritativeGeometry
        ) == true {
            return
        }
        guard let tabId = surfaceView.tabId,
              let surfaceId = action.terminalSurface?.id else { return }
        AppDelegate.shared?.tabManagerFor(tabId: tabId)?.updateReportedSurfaceDirectory(
            tabId: tabId,
            surfaceId: surfaceId,
            directory: action.directory
        )
    }
}

extension TerminalPanel {
    func performInternalBindingAction(_ action: String) -> Bool {
        guard !isAgentHibernated else { return false }
        return surface.performInternalBindingAction(action)
    }
}

extension GhosttyApp {
    func handleCurrentDirectoryAction(
        _ directory: String,
        authoritativeGeometry: NotificationScrollRestoreGeometry?,
        surfaceView: GhosttyNSView
    ) {
        let terminalSurface = surfaceView.terminalSurface
        // A bounded AsyncStream wake signal drives one MainActor consumer.
        // Ordinary PWD actions coalesce per surface; registered replay markers
        // remain ordered and cannot be displaced by terminal output floods.
        GhosttyCurrentDirectoryActionDispatcher.shared.enqueue(
            directory: directory,
            authoritativeGeometry: authoritativeGeometry,
            surfaceView: surfaceView,
            terminalSurface: terminalSurface
        )
    }
}

extension GhosttyNSView {
    func registerNotificationScrollReplayBoundaries(
        startBoundary: String,
        endBoundary: String
    ) {
        GhosttyCurrentDirectoryActionDispatcher.shared.registerReplayBoundaries(
            for: self,
            startBoundary: startBoundary,
            endBoundary: endBoundary
        )
    }

    static func retainRenderedFrameNotifications() -> () -> Void {
        // See GhosttyApp.retainTickNotifications() on the idempotent release.
        let retention = GhosttyApp.renderedFrameNotificationDemand.retain()
        return { retention.release() }
    }

    @objc dynamic func readAuthoritativeScrollbar(
        _ result: UnsafeMutablePointer<ghostty_surface_scrollbar_s>
    ) -> Bool {
        guard let surface = terminalSurface?.surface else { return false }
        return ghostty_surface_scrollbar(surface, result)
    }

    @objc dynamic func scrollToRow(
        _ row: UInt64,
        ifRowSpaceRevisionMatches rowSpaceRevision: UInt64,
        result: UnsafeMutablePointer<ghostty_surface_scrollbar_s>
    ) -> Bool {
        guard let surface = terminalSurface?.surface else { return false }
        return ghostty_surface_scroll_to_row_if_revision(
            surface,
            row,
            rowSpaceRevision,
            result
        )
    }

}
