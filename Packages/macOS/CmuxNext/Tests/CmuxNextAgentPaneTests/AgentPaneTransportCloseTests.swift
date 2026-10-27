import Foundation
import CmuxNextPages
import Testing
@testable import CmuxNextAgentPane

@MainActor
struct AgentPaneTransportCloseTests {
    @Test func closeDeliversTerminalEventBeforeClearingSocket() async throws {
        let provider = AgentPageProvider { _ in nil }
        var sawClose = false
        let subscription = try await provider.subscribe(AgentPageProvider.hostEvents, filter: .null,
                                                        context: PageCallContext(page: PageDescriptor.agent.id)) { event in
            if event["value"]?["closed"] != nil { sawClose = true }
        }
        defer { subscription.cancel() }
        for index in 0...AgentPageProvider.maximumBufferedEvents {
            provider.eventDeliveryDropped(stream: AgentPageProvider.hostEvents,
                                          data: AgentPageEvent.command("overflow-\(index)").data,
                                          publicationID: UInt64(index + 1))
        }

        let transport = AgentPaneTransport()
        let socket = AcpmuxPaneSocket(
            request: URLRequest(url: URL(string: "ws://127.0.0.1")!),
            limits: transport.limits,
            options: transport.permissionOptions,
            sessions: transport.sessions,
            ids: AcpmuxRequestIds(),
            signal: {})
        transport.socket = socket
        transport.current = 1
        var accepted = false
        var delivered: [AgentPaneTransportEvent] = []
        transport.deliver = { event, done in
            delivered.append(event)
            accepted = provider.publish(.transport(event))
            done()
        }

        transport.close(connection: 1)
        #expect(delivered.isEmpty)
        #expect(transport.connection == 1)
        _ = transport.flush()

        #expect(delivered.count == 1)
        #expect(delivered.first?.closed?.code == 1000)
        #expect(accepted)
        #expect(sawClose)
        #expect(transport.connection == nil)
    }
}
