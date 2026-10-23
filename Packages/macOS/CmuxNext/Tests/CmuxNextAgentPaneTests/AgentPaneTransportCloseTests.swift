import Foundation
import Testing
@testable import CmuxNextAgentPane

@MainActor
struct AgentPaneTransportCloseTests {
    @Test func closeDeliversTerminalEventBeforeClearingSocket() {
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
        var delivered: [AgentPaneTransportEvent] = []
        transport.deliver = { event, done in
            delivered.append(event)
            done()
        }

        transport.close(connection: 1)
        #expect(delivered.isEmpty)
        #expect(transport.connection == 1)
        _ = transport.flush()

        #expect(delivered.count == 1)
        #expect(delivered.first?.closed?.code == 1000)
        #expect(transport.connection == nil)
    }
}
