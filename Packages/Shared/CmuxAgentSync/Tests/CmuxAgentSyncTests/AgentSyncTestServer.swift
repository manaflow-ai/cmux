import CmuxAgentReplica
import CmuxAgentSync
import CmuxAgentWire
import Foundation

actor AgentSyncTestServer {
    enum SendOutcome: Sendable {
        case accepted
        case rejected
        case failure(GuiWireErrorCode)
        case transportFailure
        case malformedResponse
    }

    private var helloResult: GuiHelloResult
    private var sessionsResult: GuiSessionsResult
    private var capabilitiesResult: GuiCapabilitiesResult
    private var fallbackEntriesResult: GuiEntriesResult
    private var queuedEntriesResults: [GuiEntriesResult]
    private var queuedSendOutcomes: [SendOutcome]
    private var decodedEntriesParams: [GuiEntriesParams]
    private var decodedSendParams: [GuiSendParams]
    private var requestCounts: [String: Int]
    private var sessionsRequestAction: (@Sendable () async -> Void)?
    private var helloFailuresRemaining: Int
    private var shouldGateNextEntries: Bool
    private var entriesGate: CheckedContinuation<Void, Never>?

    init(
        epoch: ReplicaEpoch = AgentSyncTestSupport.epochOne,
        journalID: JournalID = AgentSyncTestSupport.journalOne,
        entries: [EntrySnapshot] = []
    ) {
        helloResult = AgentSyncTestSupport.hello(epoch: epoch)
        sessionsResult = GuiSessionsResult(
            epoch: epoch,
            sessions: [AgentSyncTestSupport.sessionSnapshot()]
        )
        capabilitiesResult = GuiCapabilitiesResult(
            tier: .wrapped,
            reasons: [],
            cliVersion: "1.0.0",
            steerable: true,
            answerable: true
        )
        fallbackEntriesResult = AgentSyncTestSupport.page(journalID: journalID, entries: entries)
        queuedEntriesResults = []
        queuedSendOutcomes = []
        decodedEntriesParams = []
        decodedSendParams = []
        requestCounts = [:]
        sessionsRequestAction = nil
        helloFailuresRemaining = 0
        shouldGateNextEntries = false
        entriesGate = nil
    }

    func install(on transport: FixtureSyncTransport) async {
        await transport.setHandler(method: GuiWireMethod.hello) { [weak self] params in
            guard let self else { throw FixtureSyncTransportError.unhandledRequest(GuiWireMethod.hello) }
            return try await self.handleHello(params)
        }
        await transport.setHandler(method: GuiWireMethod.sessions) { [weak self] params in
            guard let self else { throw FixtureSyncTransportError.unhandledRequest(GuiWireMethod.sessions) }
            return try await self.handleSessions(params)
        }
        await transport.setHandler(method: GuiWireMethod.entries) { [weak self] params in
            guard let self else { throw FixtureSyncTransportError.unhandledRequest(GuiWireMethod.entries) }
            return try await self.handleEntries(params)
        }
        await transport.setHandler(method: GuiWireMethod.send) { [weak self] params in
            guard let self else { throw FixtureSyncTransportError.unhandledRequest(GuiWireMethod.send) }
            return try await self.handleSend(params)
        }
        await transport.setHandler(method: GuiWireMethod.capabilities) { [weak self] params in
            guard let self else { throw FixtureSyncTransportError.unhandledRequest(GuiWireMethod.capabilities) }
            return try await self.handleCapabilities(params)
        }
    }

    func setEpoch(_ epoch: ReplicaEpoch) {
        helloResult = AgentSyncTestSupport.hello(epoch: epoch)
        sessionsResult = GuiSessionsResult(epoch: epoch, sessions: sessionsResult.sessions)
    }

    func setHelloEpoch(_ epoch: ReplicaEpoch) {
        helloResult = AgentSyncTestSupport.hello(epoch: epoch)
    }

    func setSessions(_ sessions: [AgentSessionSnapshot], epoch: ReplicaEpoch? = nil) {
        sessionsResult = GuiSessionsResult(epoch: epoch ?? sessionsResult.epoch, sessions: sessions)
    }

    func setEntriesResult(_ result: GuiEntriesResult) {
        fallbackEntriesResult = result
    }

    func enqueueEntriesResult(_ result: GuiEntriesResult) {
        queuedEntriesResults.append(result)
    }

    func setSendOutcomes(_ outcomes: [SendOutcome]) {
        queuedSendOutcomes = outcomes
    }

    func setCapabilitiesResult(_ result: GuiCapabilitiesResult) {
        capabilitiesResult = result
    }

    func setSessionsRequestAction(_ action: (@Sendable () async -> Void)?) {
        sessionsRequestAction = action
    }

    func failNextHelloRequests(_ count: Int) {
        helloFailuresRemaining = count
    }

    func gateNextEntriesRequest() {
        shouldGateNextEntries = true
    }

    func resumeEntriesRequest() {
        entriesGate?.resume()
        entriesGate = nil
    }

    func entriesParams() -> [GuiEntriesParams] {
        decodedEntriesParams
    }

    func sendParams() -> [GuiSendParams] {
        decodedSendParams
    }

    func requestCount(method: String) -> Int {
        requestCounts[method, default: 0]
    }

    private func handleHello(_ params: Data) async throws -> Data {
        _ = try JSONDecoder().decode(GuiHelloParams.self, from: params)
        requestCounts[GuiWireMethod.hello, default: 0] += 1
        if helloFailuresRemaining > 0 {
            helloFailuresRemaining -= 1
            throw GuiWireError(code: .internalError, message: "scripted hello failure")
        }
        return try JSONEncoder().encode(helloResult)
    }

    private func handleSessions(_ params: Data) async throws -> Data {
        _ = try JSONDecoder().decode(GuiSessionsParams.self, from: params)
        requestCounts[GuiWireMethod.sessions, default: 0] += 1
        if let sessionsRequestAction {
            await sessionsRequestAction()
        }
        return try JSONEncoder().encode(sessionsResult)
    }

    private func handleEntries(_ params: Data) async throws -> Data {
        let decoded = try JSONDecoder().decode(GuiEntriesParams.self, from: params)
        decodedEntriesParams.append(decoded)
        requestCounts[GuiWireMethod.entries, default: 0] += 1
        if shouldGateNextEntries {
            shouldGateNextEntries = false
            await withCheckedContinuation { continuation in
                entriesGate = continuation
            }
        }
        let result = queuedEntriesResults.isEmpty
            ? fallbackEntriesResult
            : queuedEntriesResults.removeFirst()
        return try JSONEncoder().encode(result)
    }

    private func handleSend(_ params: Data) async throws -> Data {
        let decoded = try JSONDecoder().decode(GuiSendParams.self, from: params)
        decodedSendParams.append(decoded)
        requestCounts[GuiWireMethod.send, default: 0] += 1
        let outcome = queuedSendOutcomes.isEmpty ? .accepted : queuedSendOutcomes.removeFirst()
        switch outcome {
        case .accepted:
            return try JSONEncoder().encode(GuiSendResult(accepted: true, queuedOnMac: true))
        case .rejected:
            return try JSONEncoder().encode(GuiSendResult(accepted: false, queuedOnMac: false))
        case .failure(let code):
            throw GuiWireError(code: code, message: "scripted send failure")
        case .transportFailure:
            throw FixtureSyncTransportError.unhandledRequest("scripted transport failure")
        case .malformedResponse:
            return Data("{".utf8)
        }
    }

    private func handleCapabilities(_ params: Data) async throws -> Data {
        _ = try JSONDecoder().decode(GuiCapabilitiesParams.self, from: params)
        requestCounts[GuiWireMethod.capabilities, default: 0] += 1
        return try JSONEncoder().encode(capabilitiesResult)
    }
}
