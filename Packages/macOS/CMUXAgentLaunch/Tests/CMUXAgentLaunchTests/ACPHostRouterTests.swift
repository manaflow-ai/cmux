import Foundation
import Testing
@testable import CMUXAgentLaunch

@Suite("ACP host router")
struct ACPHostRouterTests {
    private let router = ACPHostRouter()

    private func request(
        _ method: String,
        id: ACPRequestIdentifier? = .number(1),
        params: [String: Any] = [:]
    ) -> ACPIncomingMessage {
        ACPIncomingMessage(id: id, method: method, params: params)
    }

    private func failure(_ outcome: ACPRouterOutcome) throws -> (Int, String) {
        guard case .fail(_, let code, let message) = outcome else {
            Issue.record("Expected a failure outcome, got \(String(describing: outcome))")
            throw TestError.unexpectedOutcome
        }
        return (code, message)
    }

    private enum TestError: Error { case unexpectedOutcome }

    @Test("Initialize routes the negotiated protocol version through the host")
    func initializeRouteNegotiatesVersion() {
        let cases: [(Int?, Int)] = [(99, ACPHostCapabilities.protocolVersion), (0, 0), (nil, ACPHostCapabilities.protocolVersion)]
        for (requested, expected) in cases {
            let params: [String: Any] = requested.map { ["protocolVersion": $0] } ?? [:]
            guard case .respond(let id, let result) = router.route(request(
                ACPHostMethod.initialize,
                params: params
            )) else {
                Issue.record("initialize should return a response")
                continue
            }
            #expect(id == .number(1))
            #expect(result["protocolVersion"] as? Int == expected)
        }
    }

    @Test("Authenticate succeeds without advertised auth methods")
    func authenticateSucceeds() {
        guard case .respond(let id, let result) = router.route(request(ACPHostMethod.authenticate)) else {
            Issue.record("authenticate should return a response")
            return
        }
        #expect(id == .number(1))
        #expect(result.isEmpty)
    }

    @Test("The session list extension delegates to the caller")
    func listsSessions() {
        guard case .listSessions(let id) = router.route(request("_cmux/session/list")) else {
            Issue.record("The extension should request the live session registry")
            return
        }
        #expect(id == .number(1))
    }

    @Test("Notifications are always ignored, including session cancel")
    func notificationsAreNeverAnswered() {
        let methods = [
            ACPHostMethod.initialize,
            ACPHostMethod.authenticate,
            ACPHostMethod.cmuxSessionList,
            ACPHostMethod.sessionLoad,
            ACPHostMethod.sessionNew,
            ACPHostMethod.sessionPrompt,
            ACPHostMethod.sessionCancel,
            ACPHostMethod.sessionSetMode,
            "unknown/method",
        ]

        for method in methods {
            guard case .ignore(let ignoredMethod) = router.route(request(method, id: nil)) else {
                Issue.record("Notification \(method) must be ignored")
                continue
            }
            #expect(ignoredMethod == method)
        }
    }

    @Test("Session load rejects missing, non-string, empty, and whitespace-only ids")
    func sessionLoadRejectsInvalidIDs() throws {
        let invalidParameters: [[String: Any]] = [
            [:],
            ["sessionId": 42],
            ["sessionId": ""],
            ["sessionId": " \n\t "],
        ]

        for params in invalidParameters {
            let (code, message) = try failure(router.route(request(
                ACPHostMethod.sessionLoad,
                params: params
            )))
            #expect(code == ACPErrorCode.invalidParams)
            #expect(message.contains("session/load"))
        }
    }

    @Test("Session load trims a valid id before replay")
    func sessionLoadTrimsID() {
        guard case .loadSession(_, let sessionID) = router.route(request(
            ACPHostMethod.sessionLoad,
            params: ["sessionId": "  session-123  "]
        )) else {
            Issue.record("A non-empty session id should load")
            return
        }
        #expect(sessionID == "session-123")
    }

    @Test("Every deferred method names its owning phase")
    func allDeferredMethodsAreCoveredByTheTable() throws {
        for (method, phase) in ACPHostMethod.deferredMethods {
            let (code, message) = try failure(router.route(request(method)))
            #expect(code == ACPErrorCode.methodNotFound)
            #expect(message.contains(phase))
            #expect(message.contains(method))
        }
    }

    @Test("Unknown methods return methodNotFound")
    func unknownMethodFails() throws {
        let (code, message) = try failure(router.route(request("session/unknown")))
        #expect(code == ACPErrorCode.methodNotFound)
        #expect(message.contains("Unknown method"))
    }

    @Test("Undecodable lines only answer when an id or protocol error is available")
    func decodeFailuresUseJSONRPCCodes() throws {
        #expect(router.failure(for: .notJSON) == nil)
        #expect(router.failure(for: .notAnObject) == nil)

        let wrongVersion = try #require(router.failure(for: .wrongVersion("1.0")))
        #expect(wrongVersion["jsonrpc"] as? String == "2.0")
        #expect(wrongVersion["id"] is NSNull)
        #expect(errorCode(in: wrongVersion) == ACPErrorCode.invalidRequest)

        let missingMethod = try #require(router.failure(for: .missingMethod(.string("request"))))
        #expect(missingMethod["jsonrpc"] as? String == "2.0")
        #expect(errorCode(in: missingMethod) == ACPErrorCode.invalidRequest)
        #expect(missingMethod["id"] as? String == "request")

        let badParams = try #require(router.failure(for: .paramsNotAnObject(.number(7))))
        #expect(badParams["jsonrpc"] as? String == "2.0")
        #expect(errorCode(in: badParams) == ACPErrorCode.invalidParams)
        #expect(badParams["id"] as? Int == 7)
    }

    private func errorCode(in envelope: [String: Any]) -> Int? {
        (envelope["error"] as? [String: Any])?["code"] as? Int
    }
}
