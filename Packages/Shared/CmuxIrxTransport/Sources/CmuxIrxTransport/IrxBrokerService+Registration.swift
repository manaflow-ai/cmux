public import CmuxIrohTransport
internal import Foundation

extension IrxBrokerService {
    /// Serializes availability changes; only an identical queued tail can be shared.
    public func register(
        pairingEnabled: Bool,
        relayURLHint: String?,
        directAddresses: [String] = [],
        directPorts: CmxIrohDirectPorts? = nil
    ) async throws -> IrxBindingSnapshot {
        let epoch = try beginOperation()
        let parameters = RegistrationParameters(
            pairingEnabled: pairingEnabled, relayURLHint: relayURLHint,
            directAddresses: directAddresses, directPorts: directPorts
        )
        if registrationParameters == parameters, let running = registrationInFlight {
            return try await running.value
        }
        // Queue different payloads in arrival order. Only the identical tail
        // may coalesce: on -> off -> on must not reuse the first on request.
        let previous = registrationInFlight
        let operationID = UUID()
        let task = Task<IrxBindingSnapshot, any Error> {
            if let previous { _ = try? await previous.value }
            try self.requireCurrent(epoch)
            return try await self.registerOnce(
                pairingEnabled: pairingEnabled,
                relayURLHint: relayURLHint,
                directAddresses: directAddresses,
                directPorts: directPorts,
                epoch: epoch
            )
        }
        registrationInFlight = task
        registrationParameters = parameters
        registrationOperationID = operationID
        defer {
            if registrationOperationID == operationID {
                registrationInFlight = nil
                registrationParameters = nil
                registrationOperationID = nil
            }
        }
        return try await task.value
    }

}
