import CmuxAgentReplica
import CmuxAgentWire
import Foundation

extension AgentGUIService {
    func handleRPC(_ request: MobileHostRPCRequest) async -> MobileHostRPCResult? {
        await AgentGUIRPCHandler(service: self).handle(request)
    }
}

@MainActor
struct AgentGUIRPCHandler {
    private let service: AgentGUIService

    init(service: AgentGUIService) {
        self.service = service
    }

    func handle(_ request: MobileHostRPCRequest) async -> MobileHostRPCResult? {
        do {
            switch request.method {
            case GuiWireMethod.hello:
                return .ok(try hello(params: request.params))
            case GuiWireMethod.sessions:
                service.forceProcessScan()
                return .ok(try AgentGUICodableBridge.dictionary(service.sessionsResult()))
            case GuiWireMethod.session:
                let params = try AgentGUICodableBridge.decode(GuiSessionParams.self, from: request.params)
                return .ok(try AgentGUICodableBridge.dictionary(service.sessionResult(id: params.sessionID)))
            case GuiWireMethod.entries:
                let params = try AgentGUICodableBridge.decode(GuiEntriesParams.self, from: request.params)
                return .ok(try await AgentGUICodableBridge.dictionary(service.entriesResult(params: params)))
            case GuiWireMethod.send:
                let params = try AgentGUICodableBridge.decode(GuiSendParams.self, from: request.params)
                return .ok(try AgentGUICodableBridge.dictionary(service.sendResult(params: params)))
            case GuiWireMethod.interrupt:
                let params = try AgentGUICodableBridge.decode(GuiInterruptParams.self, from: request.params)
                return .ok(try AgentGUICodableBridge.dictionary(service.interruptResult(params: params)))
            case GuiWireMethod.answer:
                let params = try AgentGUICodableBridge.decode(GuiAnswerParams.self, from: request.params)
                return .ok(try AgentGUICodableBridge.dictionary(service.answerResult(params: params)))
            case GuiWireMethod.capabilities:
                let params = try AgentGUICodableBridge.decode(GuiCapabilitiesParams.self, from: request.params)
                return .ok(try AgentGUICodableBridge.dictionary(service.capabilitiesResult(params: params)))
            default:
                return nil
            }
        } catch let error as AgentGUIRPCError {
            return .failure(MobileHostRPCError(code: error.code, message: error.message, data: error.data))
        } catch {
            return .failure(MobileHostRPCError(code: AgentGUIRPCError.invalidParams.code, message: AgentGUIRPCError.invalidParams.message))
        }
    }

    private func hello(params: [String: Any]) throws -> [String: Any] {
        let hello = try AgentGUICodableBridge.decode(GuiHelloParams.self, from: params)
        guard hello.protocolMin <= 1, hello.protocolMax >= 1 else {
            throw AgentGUIRPCError.unsupportedProtocol
        }
        let result = GuiHelloResult(
            protocol: 1,
            serverCaps: [GuiWireCaps.entriesPaging, GuiWireCaps.sendTickets, GuiWireCaps.answers, GuiWireCaps.capabilitiesReport],
            epoch: service.epoch,
            macDeviceID: service.macDeviceID,
            serverTimeMS: Int64(Date().timeIntervalSince1970 * 1_000)
        )
        return try AgentGUICodableBridge.dictionary(result)
    }
}
