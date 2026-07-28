import CmuxTerminal
import Foundation

/// Nonblocking ordered handoff from Ghostty's serialized PTY callback to the
/// main actor. The latest-directory snapshot is confined to that serialized
/// callback and preserves callback order for later OSC notifications.
final class GhosttyCurrentDirectoryActionDispatcher {
    typealias Delivery = @MainActor @Sendable (GhosttyCurrentDirectoryAction) -> Void

    private let startBoundaryHash: UInt64?
    private let endBoundaryHash: UInt64?
    private let replayBoundaryContinuation: AsyncStream<GhosttyCurrentDirectoryAction>.Continuation
    private let ordinaryContinuation: AsyncStream<GhosttyCurrentDirectoryAction>.Continuation
    private var latestDirectory: String?

    init(
        startBoundary: String? = nil,
        endBoundary: String? = nil,
        delivery: Delivery? = nil
    ) {
        self.startBoundaryHash = startBoundary.map(Self.stableHash)
        self.endBoundaryHash = endBoundary.map(Self.stableHash)
        let (replayBoundaryStream, replayBoundaryContinuation) =
            AsyncStream<GhosttyCurrentDirectoryAction>.makeStream(
                bufferingPolicy: .bufferingNewest(2)
            )
        let (ordinaryStream, ordinaryContinuation) =
            AsyncStream<GhosttyCurrentDirectoryAction>.makeStream(
                bufferingPolicy: .bufferingNewest(1)
            )
        self.replayBoundaryContinuation = replayBoundaryContinuation
        self.ordinaryContinuation = ordinaryContinuation
        let resolvedDelivery: Delivery = delivery ?? { action in
            Self.deliver(action)
        }
        Task { @MainActor in
            for await action in replayBoundaryStream {
                resolvedDelivery(action)
            }
        }
        Task { @MainActor in
            for await action in ordinaryStream {
                resolvedDelivery(action)
            }
        }
    }

    deinit {
        replayBoundaryContinuation.finish()
        ordinaryContinuation.finish()
    }

    func enqueue(
        directory: String,
        authoritativeGeometry: NotificationScrollRestoreGeometry?,
        surfaceView: GhosttyNSView,
        terminalSurface: TerminalSurface?
    ) {
        latestDirectory = directory.isEmpty ? nil : directory
        let directoryHash = Self.stableHash(directory)
        let isStartBoundary = directoryHash == startBoundaryHash
        let isEndBoundary = directoryHash == endBoundaryHash
        let action = GhosttyCurrentDirectoryAction(
            directory: directory,
            authoritativeGeometry: authoritativeGeometry,
            replayBoundaryGeneration: isStartBoundary || isEndBoundary ? 0 : nil,
            surfaceView: surfaceView,
            terminalSurface: terminalSurface
        )
        if action.replayBoundaryGeneration == nil {
            ordinaryContinuation.yield(action)
        } else {
            replayBoundaryContinuation.yield(action)
        }
    }

    /// The last PWD value observed before the current callback in Ghostty's
    /// serialized surface action stream.
    func directorySnapshot() -> String? {
        latestDirectory
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
