import Foundation
import CmuxNextPages
import Testing
@testable import CmuxNextAgentPane

@MainActor
struct AgentPaneQuestionKeyAdmissionTests {
    private final class HeldPacer: AgentPaneTransportPacer {
        func schedule(_ flush: @escaping @MainActor @Sendable () -> AgentPaneFlush) {}
    }

    private static let target = PageQuestionKeyTarget(sessionID: "s", permissionID: "p1")
    private static let requestID = "question-key-close-race"
    private static let frame = #"{"jsonrpc":"2.0","id":"question-key-close-race","method":"_acpmux/permission_respond","params":{"sessionId":"s","permissionId":"p1","optionId":"yes","answers":{"q1":"Keep this answer"}}}"#

    private static func checkRefusal(_ events: [AgentPaneTransportEvent], connection: Int) throws {
        let frames = try events.filter { $0.connection == connection }.flatMap(\.frames).map {
            try #require(try JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
        }
        let announced = try #require(frames.firstIndex {
            $0["method"] as? String == "_cmux/question_key_request"
                && ($0["params"] as? [String: Any])?["id"] as? String == requestID
        })
        let refused = try #require(frames.firstIndex { $0["id"] as? String == requestID && $0["error"] != nil })
        #expect(announced < refused)
    }

    @Test func aCapturedReplyGetsARefusalWhenItsConnectionAlreadyClosed() throws {
        let transport = AgentPaneTransport()
        var events: [AgentPaneTransportEvent] = []
        transport.deliver = { event, done in events.append(event); done() }
        transport.submitQuestionKeyReply(connection: transport.current, requestID: Self.requestID,
                                         target: Self.target, frame: Self.frame)
        try Self.checkRefusal(events, connection: transport.current)
        // A snapshot arriving after reconnect must also reach its old card, never the new socket.
        events.removeAll()
        transport.submitQuestionKeyReply(connection: transport.current - 1, requestID: Self.requestID,
                                         target: Self.target, frame: Self.frame)
        try Self.checkRefusal(events, connection: transport.current - 1)
    }

    @Test(arguments: [false, true])
    func closingBeforeTheAnnouncementFlushesStillRefusesTheCapturedReply(overflow: Bool) async throws {
        let server = AcpmuxStandInServer()
        try await server.start()
        defer { server.stop() }
        let transport = AgentPaneTransport(pacer: HeldPacer())
        var events: [AgentPaneTransportEvent] = []
        transport.deliver = { event, done in events.append(event); done() }
        let connection = try await transport.open(AcpmuxConnection(url: server.url, dashboardToken: "t", localAppToken: nil))
        defer { transport.close(connection: connection) }
        transport.submitQuestionKeyReply(connection: connection, requestID: Self.requestID,
                                         target: Self.target, frame: Self.frame)
        if overflow {
            // Overflow drops the socket's inbox; the native capture must survive that loss.
            transport.socket?.close(code: 1009, reason: "overflow", error: .inboundOverflow)
            transport.flush()
        } else {
            transport.close(connection: connection)
        }
        try Self.checkRefusal(events, connection: connection)
    }

    @Test func anAnsweredCaptureIsNotRefusedAgainWhenTheConnectionCloses() async throws {
        let server = AcpmuxStandInServer()
        try await server.start()
        defer { server.stop() }
        let transport = AgentPaneTransport(pacer: HeldPacer())
        var events: [AgentPaneTransportEvent] = []
        transport.deliver = { event, done in events.append(event); done() }
        let connection = try await transport.open(AcpmuxConnection(url: server.url, dashboardToken: "t", localAppToken: nil))
        transport.submitQuestionKeyReply(connection: connection, requestID: Self.requestID,
                                         target: Self.target, frame: Self.frame)
        transport.socket?.inject(#"{"jsonrpc":"2.0","id":"question-key-close-race","result":{}}"#)
        transport.flush()
        transport.close(connection: connection)
        let frames = try events.flatMap(\.frames).map {
            try #require(try JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
        }
        #expect(frames.contains { $0["id"] as? String == Self.requestID && $0["result"] != nil })
        #expect(!frames.contains { $0["id"] as? String == Self.requestID && $0["error"] != nil })
    }
}
