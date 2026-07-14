import CmuxTerminal
import Foundation
import Synchronization

/// Nonblocking ordered handoff from Ghostty's serialized PTY callback to the
/// main actor. Mutable delivery state lives in `AsyncStream`; atomics only tag
/// the two replay markers that must survive ordinary PWD coalescing.
final class GhosttyCurrentDirectoryActionDispatcher: Sendable {
    typealias Delivery = @MainActor @Sendable (GhosttyCurrentDirectoryAction) -> Void

    private let startBoundaryHash = Atomic<UInt64>(0)
    private let endBoundaryHash = Atomic<UInt64>(0)
    private let startBoundaryPending = Atomic<Bool>(false)
    private let endBoundaryPending = Atomic<Bool>(false)
    private let boundaryGeneration = Atomic<UInt64>(0)
    private let continuation: AsyncStream<GhosttyCurrentDirectoryAction>.Continuation

    init(delivery: Delivery? = nil) {
        let (stream, continuation) = AsyncStream<GhosttyCurrentDirectoryAction>.makeStream(
            bufferingPolicy: .bufferingNewest(3)
        )
        self.continuation = continuation
        let resolvedDelivery: Delivery = delivery ?? { action in
            Self.deliver(action)
        }
        Task { @MainActor in
            for await action in stream {
                resolvedDelivery(action)
            }
        }
    }

    func registerReplayBoundaries(startBoundary: String, endBoundary: String) {
        _ = boundaryGeneration.wrappingAdd(1, ordering: .acquiringAndReleasing)
        startBoundaryHash.store(Self.stableHash(startBoundary), ordering: .releasing)
        endBoundaryHash.store(Self.stableHash(endBoundary), ordering: .releasing)
        startBoundaryPending.store(true, ordering: .releasing)
        endBoundaryPending.store(true, ordering: .releasing)
    }

    func cancelReplayBoundaries() {
        _ = boundaryGeneration.wrappingAdd(1, ordering: .acquiringAndReleasing)
        startBoundaryPending.store(false, ordering: .releasing)
        endBoundaryPending.store(false, ordering: .releasing)
    }

    func enqueue(
        directory: String,
        authoritativeGeometry: NotificationScrollRestoreGeometry?,
        surfaceView: GhosttyNSView,
        terminalSurface: TerminalSurface?
    ) {
        let directoryHash = Self.stableHash(directory)
        let generation = boundaryGeneration.load(ordering: .acquiring)
        let isStartBoundary = directoryHash == startBoundaryHash.load(ordering: .acquiring)
            && startBoundaryPending.exchange(false, ordering: .acquiringAndReleasing)
        let isEndBoundary = directoryHash == endBoundaryHash.load(ordering: .acquiring)
            && endBoundaryPending.exchange(false, ordering: .acquiringAndReleasing)
        let action = GhosttyCurrentDirectoryAction(
            directory: directory,
            authoritativeGeometry: authoritativeGeometry,
            replayBoundaryGeneration: isStartBoundary || isEndBoundary ? generation : nil,
            surfaceView: surfaceView,
            terminalSurface: terminalSurface
        )
        yieldPreservingCurrentReplayBoundary(action)
    }

    private func yieldPreservingCurrentReplayBoundary(_ action: GhosttyCurrentDirectoryAction) {
        var next: GhosttyCurrentDirectoryAction? = action
        let currentGeneration = boundaryGeneration.load(ordering: .acquiring)
        while let candidate = next {
            switch continuation.yield(candidate) {
            case .dropped(let dropped)
                where dropped.replayBoundaryGeneration == currentGeneration:
                next = dropped
            case .enqueued, .dropped, .terminated:
                next = nil
            @unknown default:
                next = nil
            }
        }
    }

    @MainActor
    private static func deliver(_ action: GhosttyCurrentDirectoryAction) {
        guard let surfaceView = action.surfaceView else { return }
        if action.terminalSurface?.hostedView.sessionScrollbackReplayDidReceiveBoundary(
            action.directory,
            authoritativeGeometry: action.authoritativeGeometry
        ) == true || action.replayBoundaryGeneration != nil {
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

    private static func stableHash(_ value: String) -> UInt64 {
        value.utf8.reduce(0xcbf29ce484222325) { hash, byte in
            (hash ^ UInt64(byte)) &* 0x100000001b3
        }
    }
}
