public import Foundation

/// A provider carrier pinned to one ready control transport, including across reconnects.
public nonisolated final class AppProviderSession: Sendable {
    /// The connection instance that emitted this carrier's side events.
    public let sourceID: UUID
    /// The ready control serial inside that instance.
    public let serial: UInt64
    private let ready: DaemonReadyConnection

    /// Captures the current ready carrier without waiting or opening a connection.
    /// - Parameter connection: An existing ready app-provider connection.
    /// - Parameter expectedStamp: The registry's applied connected event, when admission must be fenced.
    /// - Throws: No ready transport or missing provider capability.
    public init(connection: isolated DaemonConnection, expectedStamp: DaemonControlStamp? = nil) throws {
        guard let ready = connection.ready else { throw DaemonError.notConnected }
        guard ready.identity.supports("apps-v1") else { throw DaemonError.missingCapabilities(["apps-v1"]) }
        if let expectedStamp {
            guard expectedStamp.sourceID == connection.eventSourceID, expectedStamp.serial == ready.serial else { throw DaemonError.notConnected }
        }
        self.ready = ready; sourceID = connection.eventSourceID; serial = ready.serial
    }

    /// Matches original event stamps; source metadata alone grants no authority.
    /// - Parameter envelope: The unchanged event received by the store.
    /// - Returns: Whether it came from this exact control transport.
    public func matches(_ envelope: DaemonEventEnvelope) -> Bool {
        envelope.sourceID == sourceID && envelope.connectionSerial == serial
    }

    /// Registers the supported families and negotiates inventory demand without reconnecting.
    /// - Parameter families: The app's complete implemented family set.
    /// - Returns: Demand when the new carrier is served, nil for legacy registration.
    /// - Throws: Cancellation, native refusal, decode or captured transport failure.
    public func register(families: [String]) async throws -> AgentInventoryProviderDemand? {
        try Task.checkCancellation()
        let executor = DaemonRequestExecutor(transport: ready.transport)
        if families.contains("agent_cli"), ready.identity.supports("agent-cli-app-invalidation-v1") {
            let reply = try await executor.perform(AgentInventoryProviderRegisterRequest(families: families), timeout: .seconds(15))
            guard Set(reply.families) == Set(families) else { throw DaemonError.malformedResponse("Provider families did not match registration") }
            return reply.inventoryDemand
        }
        let compatible = ready.identity.supports("agent-cli-app-provider-v1") ? families : families.filter { $0 != "agent_cli" }
        _ = try await executor.perform(AppsProviderRegisterRequest(families: compatible), timeout: .seconds(15))
        return nil
    }

    /// Sends only an invalidation on the original carrier; native permission is rechecked.
    /// - Parameter sequence: The current enabled demand generation.
    /// - Throws: Missing capability, stale demand, refusal or transport failure.
    public func invalidate(sequence: UInt64) async throws {
        try AgentInventoryProviderChangedRequest.requireServed(by: ready.identity)
        _ = try await DaemonRequestExecutor(transport: ready.transport).perform(
            AgentInventoryProviderChangedRequest(demandSequence: sequence), timeout: .seconds(15))
    }

    /// Answers a routed call on its original provider transport, even after reconnect.
    /// - Parameters:
    ///   - requestID: The supervisor request on this captured carrier.
    ///   - ok: Whether the owner handler succeeded.
    ///   - body: The app ABI result or refusal body.
    /// - Throws: A captured transport or native reply failure; no replacement is used.
    public func answer(requestID: UInt64, ok: Bool, body: JSONValue) async throws {
        _ = try await DaemonRequestExecutor(transport: ready.transport).perform(
            AppsProviderResultRequest(requestID: requestID, ok: ok, body: body), timeout: .seconds(15))
    }
}
