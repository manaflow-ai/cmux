import Foundation

/// A navigation candidate read directly from a live terminal runtime, not saved metadata.
public struct CodexWriterSurfaceIdentity: Equatable, Sendable {
    /// Workspace or rendered Dock that currently owns the surface.
    public let containerID: UUID
    /// Panel owning the runtime.
    public let surfaceID: UUID
    /// Runtime generation to revalidate after asynchronous process inspection.
    public let generation: UInt64
    /// Foreground process read from that runtime, never a stored tty label.
    public let foregroundPID: Int
    /// Kernel device captured for this exact runtime's PTY lifecycle.
    public let ttyDevice: Int64

    /// Captures the identity of a live local terminal candidate.
    /// - Parameters:
    ///   - containerID: Current owning container.
    ///   - surfaceID: Current owning panel.
    ///   - generation: Current terminal runtime generation.
    ///   - foregroundPID: Current foreground process identifier.
    ///   - ttyDevice: Current runtime's controlling-terminal device, not a saved name.
    public init(containerID: UUID, surfaceID: UUID, generation: UInt64, foregroundPID: Int, ttyDevice: Int64) {
        self.containerID = containerID
        self.surfaceID = surfaceID
        self.generation = generation
        self.foregroundPID = foregroundPID
        self.ttyDevice = ttyDevice
    }
}
