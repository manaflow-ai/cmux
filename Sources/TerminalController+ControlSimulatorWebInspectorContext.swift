import CmuxControlSocket
import CmuxSimulator
import CmuxSimulatorUI
import Foundation

extension TerminalController {
    func controlSimulatorBeginWebInspectorTargets(
        routing: ControlRoutingSelectors
    ) -> ControlSimulatorWebInspectorStartResolution {
        beginWebInspectorOperation(routing: routing, requiresSession: false) { coordinator, surfaceID, receipt in
            do {
                _ = try await coordinator.refreshWebInspectorTargetsResult()
                receipt.complete(.targets(self.controlWebInspectorSnapshot(
                    coordinator,
                    surfaceID: surfaceID
                )))
            } catch {
                self.completeWebInspectorFailure(receipt, error: error)
            }
        }
    }

    func controlSimulatorBeginWebInspectorAttach(
        routing: ControlRoutingSelectors,
        targetID: String
    ) -> ControlSimulatorWebInspectorStartResolution {
        beginWebInspectorOperation(routing: routing, requiresSession: false) { coordinator, _, receipt in
            do {
                let session = try await coordinator.attachWebInspectorResult(targetID: targetID)
                receipt.complete(.session(self.controlWebInspectorSession(session)))
            } catch {
                self.completeWebInspectorFailure(receipt, error: error)
            }
        }
    }

    func controlSimulatorBeginWebInspectorSend(
        routing: ControlRoutingSelectors,
        json: String
    ) -> ControlSimulatorWebInspectorStartResolution {
        beginWebInspectorOperation(routing: routing, requiresSession: true, timeout: 20) {
            coordinator,
            _, receipt in
            do {
                let response = try await coordinator.sendWebInspectorMessageAwaitingResponse(json)
                receipt.complete(.response(json: response.text, truncated: response.isTruncated))
            } catch {
                self.completeWebInspectorFailure(receipt, error: error)
            }
        }
    }

    func controlSimulatorBeginWebInspectorHighlight(
        routing: ControlRoutingSelectors,
        enabled: Bool
    ) -> ControlSimulatorWebInspectorStartResolution {
        beginWebInspectorOperation(routing: routing, requiresSession: true) { coordinator, _, receipt in
            do {
                _ = try await coordinator.setWebInspectorHighlightResult(enabled: enabled)
                receipt.complete(.highlighted(enabled))
            } catch {
                self.completeWebInspectorFailure(receipt, error: error)
            }
        }
    }

    func controlSimulatorBeginWebInspectorRelease(
        routing: ControlRoutingSelectors
    ) -> ControlSimulatorWebInspectorStartResolution {
        beginWebInspectorOperation(routing: routing, requiresSession: true) { coordinator, _, receipt in
            do {
                guard try await coordinator.releaseWebInspectorResult() else {
                    receipt.complete(.failed(
                        code: "web_inspector_release_failed",
                        message: String(
                            localized: "cli.simulator.error.webInspectorReleaseFailed",
                            defaultValue: "The Web Inspector session could not be released"
                        )
                    ))
                    return
                }
                receipt.complete(.released)
            } catch {
                self.completeWebInspectorFailure(receipt, error: error)
            }
        }
    }

    private func beginWebInspectorOperation(
        routing: ControlRoutingSelectors,
        requiresSession: Bool,
        timeout: TimeInterval = 15,
        operation: @escaping @MainActor @Sendable (
            SimulatorPaneCoordinator,
            UUID,
            ControlSimulatorWebInspectorReceipt
        ) async -> Void
    ) -> ControlSimulatorWebInspectorStartResolution {
        guard CmuxFeatureFlags.shared.isSimulatorEnabled else { return .unavailable }
        switch resolveSimulatorPanel(routing: routing) {
        case .unavailable:
            return .unavailable
        case let .failure(failure):
            return .failed(failure)
        case let .panel(panel):
            let coordinator = panel.coordinator
            if coordinator.status == .streaming,
               coordinator.supports(.webInspector),
               requiresSession,
               case .detached = coordinator.webInspectorSession {
                return .sessionDetached
            }
            let receipt = ControlSimulatorWebInspectorReceipt()
            let task = Task { @MainActor [weak coordinator] in
                guard let coordinator else {
                    receipt.complete(.failed(
                        code: "simulator_closed",
                        message: String(
                            localized: "cli.simulator.error.paneClosed",
                            defaultValue: "The Simulator pane closed before the operation started"
                        )
                    ))
                    return
                }
                do {
                    await coordinator.start()
                    try await coordinator.waitForSelectedDeviceStreaming()
                    try await coordinator.waitForCapabilityHydration()
                    guard coordinator.supports(.webInspector) else {
                        throw SimulatorFailure(
                            code: "simulator_capability_unavailable",
                            message: String(
                                localized: "cli.simulator.error.capabilityUnavailable",
                                defaultValue: "The active Simulator worker does not support this operation"
                            ),
                            isRecoverable: true
                        )
                    }
                    if requiresSession, case .detached = coordinator.webInspectorSession {
                        receipt.complete(.failed(
                            code: "web_inspector_session_detached",
                            message: String(
                                localized: "cli.simulator.error.webInspectorDetached",
                                defaultValue: "No Web Inspector target is attached"
                            )
                        ))
                        return
                    }
                } catch {
                    self.completeWebInspectorFailure(receipt, error: error)
                    return
                }
                await operation(coordinator, panel.id, receipt)
            }
            receipt.installCancellation { task.cancel() }
            return .started(surfaceID: panel.id, timeoutSeconds: timeout, receipt: receipt)
        }
    }

    private func completeWebInspectorFailure(
        _ receipt: ControlSimulatorWebInspectorReceipt,
        error: Error
    ) {
        if let failure = error as? SimulatorFailure {
            receipt.complete(.failed(code: failure.code, message: failure.message))
        } else {
            receipt.complete(.failed(
                code: "web_inspector_failed",
                message: String(
                    localized: "cli.simulator.error.webInspectorFailed",
                    defaultValue: "The Web Inspector operation failed"
                )
            ))
        }
    }

    private func controlWebInspectorSnapshot(
        _ coordinator: SimulatorPaneCoordinator,
        surfaceID: UUID
    ) -> ControlSimulatorWebInspectorSnapshot {
        ControlSimulatorWebInspectorSnapshot(
            surfaceID: surfaceID,
            targets: coordinator.webInspectorTargets.map(controlWebInspectorTarget),
            session: controlWebInspectorSession(coordinator.webInspectorSession),
            isHighlighted: coordinator.webInspectorIsHighlighted
        )
    }

    private func controlWebInspectorTarget(
        _ target: SimulatorWebInspectorTarget
    ) -> ControlSimulatorWebInspectorTargetSnapshot {
        ControlSimulatorWebInspectorTargetSnapshot(
            id: target.id,
            applicationIdentifier: target.applicationIdentifier,
            pageIdentifier: target.pageIdentifier,
            title: target.title,
            url: target.url,
            type: target.type,
            applicationName: target.applicationName,
            bundleIdentifier: target.bundleIdentifier,
            isInUse: target.isInUse
        )
    }

    private func controlWebInspectorSession(
        _ status: SimulatorWebInspectorSessionStatus
    ) -> ControlSimulatorWebInspectorSessionSnapshot {
        switch status {
        case .detached: .detached
        case let .attached(sessionID, targetID):
            .attached(sessionID: sessionID, targetID: targetID)
        }
    }
}
