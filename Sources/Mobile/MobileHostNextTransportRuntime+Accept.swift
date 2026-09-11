#if DEBUG
import CMUXMobileCore
import CmuxAuthRuntime
import CmuxIrohTransport
import CmuxNextTransport
import Foundation
import IrohLib
import Observation
import OSLog

extension MobileHostNextTransportRuntime {
    // MARK: - Accept loop (concurrent serves; hello deadline per connection)

    func startAcceptLoop(endpoint: Endpoint, host: TransportHost, generation gen: UInt64) {
        let sleep = self.sleep
        acceptTask = Task { [weak self] in
            var accepted = 0
            var retry = NextTransportAcceptRetryPolicy()
            while !Task.isCancelled {
                do {
                    guard let connection = try await IrohSubstrate().acceptOne(endpoint: endpoint)
                    else { break }
                    guard let self, self.generation == gen, !Task.isCancelled else {
                        await connection.closeAll(reason: nil)
                        return
                    }
                    retry.reset()
                    accepted += 1
                    MobileHostNextTransportRuntime.logger.notice(
                        """
                        host accept-loop connection #\(accepted, privacy: .public) \
                        spawning serve task
                        """)
                    // Serve in a child task so a peer that never sends its hello
                    // (or a long admission) can never wedge subsequent accepts.
                    self.registerServeTask(
                        connection: connection, host: host, number: accepted, generation: gen)
                } catch {
                    guard !Task.isCancelled, !endpoint.isClosed() else { return }
                    MobileHostNextTransportRuntime.logger.error(
                        "host accept-loop transient failure: \(String(describing: error), privacy: .public)")
                    // Avoid a hot loop when a malformed incoming handshake is
                    // rejected before the endpoint itself closes.
                    do { try await retry.waitAfterFailure(sleep: sleep) }
                    catch { return }
                }
            }
            MobileHostNextTransportRuntime.logger.notice("host accept-loop exit (endpoint closed)")
        }
    }

    private func registerServeTask(
        connection: IrohPeerConnection, host: TransportHost, number: Int, generation gen: UInt64
    ) {
        serveTaskCounter &+= 1
        let id = serveTaskCounter
        let task = Task { [weak self] in
            // TransportHost bounds the hello read itself. Admission and
            // supersession must not inherit a second, outer hello timer.
            await host.serve(connection: connection, now: Int64(Date().timeIntervalSince1970))
            guard let admitted = await host.activeSession(for: connection) else {
                MobileHostNextTransportRuntime.logger.notice(
                    """
                    host serve-task connection #\(number, privacy: .public) \
                    NOT admitted (denied or closed during serve); no bridge
                    """)
                self?.serveTasks.removeValue(forKey: id)
                return
            }
            guard let self, self.generation == gen else {
                await host.closeSession(for: connection, reason: .modeSwitched)
                self?.serveTasks.removeValue(forKey: id)
                return
            }
            // Count only CONFIRMED admissions (activeSession proved it).
            self.admissions &+= 1
            MobileHostNextTransportRuntime.logger.notice(
                """
                host serve-task connection #\(number, privacy: .public) \
                ADMITTED session=\(admitted.id, privacy: .public) \
                device=\(String(admitted.grant.deviceID.prefix(8)), privacy: .public); \
                starting bridge
                """)
            // Router slice: an admitted connection gets the full legacy
            // application service (control RPC, lane router, server events)
            // bridged over its raw streams. The bridge runs for the session
            // lifetime inside this tracked task, so stop() can cancel it.
            let isCurrent: @Sendable () async -> Bool = { [weak self] in
                let runtime = self
                let enabledAndCurrent = await MainActor.run {
                    guard let runtime else { return false }
                    return runtime.isEnabled && runtime.generation == gen
                }
                guard enabledAndCurrent else { return false }
                return !(await connection.isClosed)
            }
            await MobileHostNextTransportBridge.run(
                connection: connection,
                grant: admitted.grant,
                deviceKey: admitted.deviceKey,
                isCurrent: isCurrent)
            self.serveTasks.removeValue(forKey: id)
        }
        serveTasks[id] = task
    }

}
#endif
