import CmuxIrohTransport

/// Owns the legacy coupled lifetime of one admitted Iroh connection.
enum MobileHostIrohConnectionSupervisor {
    typealias Operation = @Sendable () async -> Void

    static func runLegacyCoupled(
        session: CmxIrohAdmittedServerSession,
        isCurrent: @escaping CmxIrohHostRuntime.CurrentGeneration
    ) async {
        let eventWriter = MobileHostIrohServerEventWriter(session: session)
        let laneRouter = MobileHostIrohApplicationLaneRouter(session: session)
        await runLegacyCoupled(
            runControl: {
                await MobileHostService.acceptTransport(
                    session.controlTransport,
                    authorization: .irohAdmission(session.peer),
                    independentEventWriter: eventWriter,
                    isCurrent: isCurrent
                )
            },
            runLanes: {
                await laneRouter.run(isCurrent: isCurrent)
            },
            closeSession: {
                await session.close()
            },
            stopLanes: {
                await laneRouter.stop()
            }
        )
    }

    static func runLegacyCoupled(
        runControl: @escaping Operation,
        runLanes: @escaping Operation,
        closeSession: @escaping Operation,
        stopLanes: @escaping Operation
    ) async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                await runControl()
            }
            group.addTask {
                await runLanes()
            }
            _ = await group.next()
            group.cancelAll()
            await closeSession()
            await stopLanes()
        }
    }
}
