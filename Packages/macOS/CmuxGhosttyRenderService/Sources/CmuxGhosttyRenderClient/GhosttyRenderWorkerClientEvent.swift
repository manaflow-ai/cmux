public import Foundation

/// Supervision events emitted by the host-side render worker client.
public enum GhosttyRenderWorkerClientEvent: Equatable, Sendable {
    /// The child accepted the current protocol generation.
    case initialized(workerGeneration: UInt64, processIdentifier: Int32)

    /// A mirror generation is ready.
    case surfaceCreated(surfaceID: UUID, surfaceGeneration: UInt64)

    /// A mirror applied output through this exclusive byte position.
    case outputApplied(surfaceID: UUID, surfaceGeneration: UInt64, nextSequence: UInt64)

    /// A child exited or its control channel failed.
    case workerExited(workerGeneration: UInt64)

    /// The worker lost volatile terminal state and needs an authoritative host
    /// screen snapshot before queued mutations can resume.
    case resynchronizationRequired(surfaceID: UUID, surfaceGeneration: UInt64)

    /// A recoverable worker diagnostic.
    case failure(String)
}
