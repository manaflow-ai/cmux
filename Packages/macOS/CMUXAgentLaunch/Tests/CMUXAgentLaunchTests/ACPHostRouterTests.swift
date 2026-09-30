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
        let value: (Int, String)? = {
            guard case .fail(_, let code, let message) = outcome else { return nil }
            return (code, message)
        }()
        return try #require(value)
    }

    private func response(_ outcome: ACPRouterOutcome) -> (ACPRequestIdentifier, [String: Any])? {
        guard case .respond(let id, let result) = outcome else { return nil }
        return (id, result)
    }

    private func errorCode(in envelope: [String: Any]) -> Int? {
        (envelope["error"] as? [String: Any])?["code"] as? Int
    }

    @Test("Initialize routes the host protocol version")
    func initializeRouteReturnsHostVersion() throws {
        let result = try #require(response(router.route(request(
            ACPHostMethod.initialize.rawValue,
            params: ["protocolVersion": 99]
        ))))
        #expect(result.0 == .number(1))
        #expect(result.1["protocolVersion"] as? Int == ACPHostCapabilities().protocolVersion)
    }

    @Test("Authenticate succeeds without advertised auth methods")
    func authenticateSucceeds() throws {
        let result = try #require(response(router.route(request(ACPHostMethod.authenticate.rawValue))))
        #expect(result.0 == .number(1))
        #expect(result.1.isEmpty)
    }

    @Test("The session list extension delegates to the caller")
    func listsSessions() throws {
        guard case .listSessions(let id) = router.route(request(ACPHostMethod.cmuxSessionList.rawValue)) else {
            throw TestError.unexpectedOutcome
        }
        #expect(id == .number(1))
    }

    @Test("Notifications are always ignored, including session cancel")
    func notificationsAreNeverAnswered() {
        let methods = ACPHostMethod.allCases.map(\.rawValue) + ["unknown/method"]

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
                ACPHostMethod.sessionLoad.rawValue,
                params: params
            )))
            #expect(code == ACPErrorCode.invalidParams.rawValue)
            #expect(message.contains("session/load"))
        }
    }

    @Test("Session load trims a valid id before replay")
    func sessionLoadTrimsID() throws {
        guard case .loadSession(_, let sessionID) = router.route(request(
            ACPHostMethod.sessionLoad.rawValue,
            params: ["sessionId": "  session-123  "]
        )) else {
            throw TestError.unexpectedOutcome
        }
        #expect(sessionID == "session-123")
    }

    @Test("Every deferred method is explicitly covered by its phase contract")
    func allDeferredMethodsAreCoveredByTheContract() throws {
        let expected: [(String, String)] = [
            (ACPHostMethod.sessionNew.rawValue, "phase 2"),
            (ACPHostMethod.sessionPrompt.rawValue, "phase 2"),
            (ACPHostMethod.sessionCancel.rawValue, "phase 2"),
            (ACPHostMethod.sessionSetMode.rawValue, "phase 3"),
        ]
        #expect(ACPHostMethod.deferredMethods == Dictionary(uniqueKeysWithValues: expected))

        for (method, phase) in expected {
            let (code, message) = try failure(router.route(request(method)))
            #expect(code == ACPErrorCode.methodNotFound.rawValue)
            #expect(message.contains(phase))
            #expect(message.contains(method))
        }
    }

    @Test("Unknown methods return methodNotFound")
    func unknownMethodFails() throws {
        let (code, message) = try failure(router.route(request("session/unknown")))
        #expect(code == ACPErrorCode.methodNotFound.rawValue)
        #expect(message.contains("Unknown method"))
    }

    @Test("A notification this host sends is not answered as a request")
    func notificationMethodIsNotARequest() throws {
        // session/update travels host to client. A client that sends it has the
        // direction backwards, which is a different mistake from a typo, so the
        // message must not call the name unknown.
        let (code, message) = try failure(router.route(request(ACPHostMethod.sessionUpdate.rawValue)))
        #expect(code == ACPErrorCode.methodNotFound.rawValue)
        #expect(message.contains("is not a request this host answers"))
        #expect(message.contains("Unknown method") == false)
    }

    @Test("Undecodable lines use JSON-RPC error codes")
    func decodeFailuresUseJSONRPCCodes() throws {
        let parse = try #require(router.failure(for: .notJSON))
        #expect(errorCode(in: parse) == ACPErrorCode.parseError.rawValue)
        #expect(parse["id"] is NSNull)

        let object = try #require(router.failure(for: .notAnObject))
        #expect(errorCode(in: object) == ACPErrorCode.invalidRequest.rawValue)
        #expect(object["id"] is NSNull)

        let wrongVersion = try #require(router.failure(for: .wrongVersion("1.0")))
        #expect(errorCode(in: wrongVersion) == ACPErrorCode.invalidRequest.rawValue)

        let missingMethod = try #require(router.failure(for: .missingMethod(.string("request"))))
        #expect(errorCode(in: missingMethod) == ACPErrorCode.invalidRequest.rawValue)
        #expect(missingMethod["id"] as? String == "request")

        let badParams = try #require(router.failure(for: .paramsNotAnObject(.number(7))))
        #expect(errorCode(in: badParams) == ACPErrorCode.invalidParams.rawValue)
        #expect(badParams["id"] as? Int == 7)
    }

    private enum TestError: Error { case unexpectedOutcome }
}
