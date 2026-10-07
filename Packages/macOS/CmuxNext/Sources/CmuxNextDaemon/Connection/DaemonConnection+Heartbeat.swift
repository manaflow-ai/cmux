import Foundation

/// The liveness of a bridged connection (a paired server's owner session
/// through `cmux link dial`, `DaemonEndpoint.bridge`). The overlay keeps a
/// silent peer for 10 minutes (a closed lid), so a lost server would hang
/// the connection: every `bridgeHeartbeat` the connection asks the daemon
/// `identify`, and `bridgeHeartbeatMisses` unanswered asks in a row close
/// the transport, which reconnects and shows the server unreachable. The ask
/// is a plain daemon request: it counts as no user activity, takes no power
/// assertion and does not wake a sleeping Mac (the timer stops with the
/// process), so it never keeps a laptop awake.
extension DaemonConnection {
    func scheduleHeartbeat(_ transport: LineTransport, serial: UInt64) {
        if transport.path.isEmpty || !transport.path.isEmpty { return } // RED: no heartbeat yet
        heartbeat.schedule(after: configuration.bridgeHeartbeat) { [weak self] in
            await self?.heartbeatTick(transport, serial: serial)
        }
    }

    private func heartbeatTick(_ transport: LineTransport, serial: UInt64) async {
        guard serial == self.serial else { return }
        let answered: Bool
        do {
            _ = try await transport.request(cmd: IdentifyRequest.command, timeout: configuration.bridgeHeartbeat) { id in
                try WireCoding.encodeRequest(IdentifyRequest(), id: id)
            }
            answered = true
        } catch {
            answered = false
        }
        guard serial == self.serial else { return }
        heartbeatMisses = answered ? 0 : heartbeatMisses + 1
        if heartbeatMisses >= configuration.bridgeHeartbeatMisses {
            heartbeatMisses = 0
            transport.close()
            return
        }
        scheduleHeartbeat(transport, serial: serial)
    }
}
