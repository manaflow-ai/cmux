/// Public-kernel process start timestamp paired with a renderer PID.
public struct TerminalRenderProcessInstanceToken: Equatable, Hashable, Sendable {
    public let startTimeSeconds: UInt64
    public let startTimeMicroseconds: UInt64

    public init(startTimeSeconds: UInt64, startTimeMicroseconds: UInt64) {
        self.startTimeSeconds = startTimeSeconds
        self.startTimeMicroseconds = startTimeMicroseconds
    }
}

/// The kernel-authenticated identity expected to send renderer frames.
public struct TerminalRenderWorkerIdentity: Equatable, Sendable {
    /// The renderer worker process ID expected in the Mach audit trailer.
    public let processID: Int32

    /// The effective user ID expected in the Mach audit trailer.
    public let effectiveUserID: UInt32

    /// Kernel process-lifetime token learned from the daemon control plane.
    public let processInstanceToken: TerminalRenderProcessInstanceToken

    /// Creates a worker identity.
    ///
    /// - Parameters:
    ///   - processID: A positive renderer worker process ID.
    ///   - effectiveUserID: The renderer worker's effective user ID.
    /// - Throws: ``TerminalRenderFrameProtocolError/invalidWorkerIdentity`` for a non-positive PID.
    public init(
        processID: Int32,
        effectiveUserID: UInt32,
        processInstanceToken: TerminalRenderProcessInstanceToken
    ) throws {
        guard processID > 0 else {
            throw TerminalRenderFrameProtocolError.invalidWorkerIdentity
        }
        self.processID = processID
        self.effectiveUserID = effectiveUserID
        self.processInstanceToken = processInstanceToken
    }
}
