import CmuxTerminal
import Foundation

/// Owns notification demand and observers for one active inline-image session.
@MainActor
final class TerminalInlineImageEventSubscription {
    private var observers: [NSObjectProtocol] = []
    private var releaseFrameDemand: (() -> Void)?
    private var releaseOutputDemand: (@Sendable () -> Void)?

    init(
        surfaceView: GhosttyNSView,
        terminalSurface: TerminalSurface,
        outputService: TerminalInlineImageOutputService,
        onRenderedFrame: @escaping @MainActor () -> Void,
        onOutput: @escaping @MainActor () -> Void,
        onBindingAction: @escaping @MainActor () -> Void
    ) {
        let center = NotificationCenter.default
        let surfaceID = terminalSurface.id
        releaseFrameDemand = GhosttyNSView.retainRenderedFrameNotifications()
        releaseOutputDemand = outputService.retainNotifications(for: surfaceID)
        observers.append(center.addObserver(
            forName: .ghosttyDidRenderFrame,
            object: surfaceView,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated { onRenderedFrame() }
        })
        observers.append(center.addObserver(
            forName: outputService.notificationName(for: surfaceID),
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated { onOutput() }
        })
        observers.append(center.addObserver(
            forName: .terminalSurfaceDidPerformBindingAction,
            object: terminalSurface,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated { onBindingAction() }
        })
    }

    func cancel() {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
        releaseFrameDemand?()
        releaseFrameDemand = nil
        releaseOutputDemand?()
        releaseOutputDemand = nil
    }

    deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        releaseFrameDemand?()
        releaseOutputDemand?()
    }
}
