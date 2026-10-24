import Foundation

extension DaemonConnection {
    /// The ready connection as a carrier of terminal streams, or nil: streams
    /// turned off (``DaemonConnectionConfiguration/terminalStreams``),
    /// or the daemon does not serve `attach-streams-v1` (an older build: views
    /// open their own connections).
    ///
    /// The first call of each connect declares the views' sizing identity once
    /// for the connection (`set-client-info` with `shared-sizing-v1` and
    /// `device`; the daemon merges it into the handshake's): the declaration
    /// every per-view connection used to send for itself.
    ///
    /// - Throws: `DaemonError.notConnected` while the connection is down, so a
    ///   view waits for it (its attach retries) instead of opening a connection
    ///   of its own meanwhile.
    public func terminalStreams(device: TerminalSizingDevice?) async throws -> TerminalStreamCarrier? {
        guard configuration.terminalStreams else { return nil }
        guard let ready else { throw DaemonError.notConnected }
        guard ready.identity.supports(DaemonCapabilities.attachStreams),
              configuration.advertisedCapabilities.contains(DaemonCapabilities.attachStreams)
        else { return nil }
        if let device {
            try await declareStreamSizing(device, on: ready)
        }
        let frames = ready.identity.supports(DaemonCapabilities.attachFrames)
            && configuration.advertisedCapabilities.contains(DaemonCapabilities.attachFrames)
        return TerminalStreamCarrier(transport: ready.transport, identity: ready.identity, frames: frames)
    }

    /// One `set-client-info` per connect, shared by every caller of this
    /// connect (a failed one is tried again by the next caller).
    private func declareStreamSizing(_ device: TerminalSizingDevice, on ready: DaemonReadyConnection) async throws {
        if let declared = streamSizingDeclaration, declared.serial == ready.serial {
            return try await declared.task.value
        }
        let transport = ready.transport
        // task-owner: the declaration of this connect; callers await it, a new connect replaces it
        let task = Task {
            _ = try await Self.perform(SetClientInfoRequest(
                name: nil, kind: nil, capabilities: [DaemonCapabilities.sharedSizing],
                deviceKind: device.kind, deviceName: device.name), on: transport)
        }
        streamSizingDeclaration = (ready.serial, task)
        do {
            try await task.value
        } catch {
            if streamSizingDeclaration?.serial == ready.serial { streamSizingDeclaration = nil }
            throw error
        }
    }
}
