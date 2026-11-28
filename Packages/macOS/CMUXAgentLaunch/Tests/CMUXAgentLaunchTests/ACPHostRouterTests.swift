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

    private func failure(_ outcome: ACPRouterOutcome) throws -> (ACPErrorCode, String) {
        let value: (ACPErrorCode, String)? = {
            guard case .fail(_, let code, let message) = outcome else { return nil }
            return (code, message)
        }()
        return try #require(value)
    }

    /// Valid `session/load` params, so a test that is about one field does not
    /// pass for want of another.
    private func loadParams(
        sessionId: Any? = "session-123",
        cwd: Any? = "/tmp/session"
    ) -> [String: Any] {
        var params: [String: Any] = [:]
        if let sessionId { params["sessionId"] = sessionId }
        if let cwd { params["cwd"] = cwd }
        return params
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
        #expect(result.1["protocolVersion"] as? Int == 1)
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
        let invalidIDs: [Any?] = [nil, 42, "", " \n\t "]

        for sessionId in invalidIDs {
            let (code, message) = try failure(router.route(request(
                ACPHostMethod.sessionLoad.rawValue,
                params: loadParams(sessionId: sessionId)
            )))
            #expect(code == .invalidParams)
            #expect(message.contains("sessionId"))
        }
    }

    @Test("Session load requires an absolute cwd")
    func sessionLoadRequiresAbsoluteCWD() throws {
        // ACP makes cwd required and absolute, and it is the base for every
        // relative path in the replayed updates, so a relative one is rejected
        // rather than accepted and silently ignored.
        let invalidCWDs: [Any?] = [nil, 42, "", "   ", "relative/dir", "~/session"]

        for cwd in invalidCWDs {
            let (code, message) = try failure(router.route(request(
                ACPHostMethod.sessionLoad.rawValue,
                params: loadParams(cwd: cwd)
            )))
            #expect(code == .invalidParams)
            #expect(message.contains("cwd"))
        }
    }

    @Test("Session load trims a valid id and carries the cwd before replay")
    func sessionLoadTrimsIDAndCarriesCWD() throws {
        guard case .loadSession(_, let sessionID, let cwd) = router.route(request(
            ACPHostMethod.sessionLoad.rawValue,
            params: loadParams(sessionId: "  session-123  ", cwd: "/tmp/session")
        )) else {
            throw TestError.unexpectedOutcome
        }
        #expect(sessionID == "session-123")
        #expect(cwd == "/tmp/session")
    }

    @Test("Every deferred method is explicitly covered by its phase contract")
    func allDeferredMethodsAreCoveredByTheContract() throws {
        let expected: [(ACPHostMethod, String)] = [
            (.sessionNew, "phase 2"),
            (.sessionPrompt, "phase 2"),
            (.sessionCancel, "phase 2"),
            (.sessionSetMode, "phase 3"),
        ]
        #expect(ACPHostMethod.deferredMethods == Dictionary(uniqueKeysWithValues: expected))

        for (method, phase) in expected {
            let (code, message) = try failure(router.route(request(method.rawValue)))
            #expect(code == .methodNotFound)
            #expect(message.contains(phase))
            #expect(message.contains(method.rawValue))
        }
    }

    @Test("Unknown methods return methodNotFound")
    func unknownMethodFails() throws {
        let (code, message) = try failure(router.route(request("session/unknown")))
        #expect(code == .methodNotFound)
        #expect(message.contains("Unknown method"))
    }

    @Test("A notification this host sends is not answered as a request")
    func notificationMethodIsNotARequest() throws {
        // session/update travels host to client. A client that sends it has the
        // direction backwards, which is a different mistake from a typo, so the
        // message must not call the name unknown.
        let (code, message) = try failure(router.route(request(ACPHostMethod.sessionUpdate.rawValue)))
        #expect(code == .methodNotFound)
        #expect(message.contains("is not a request this host answers"))
        #expect(message.contains("Unknown method") == false)
    }

    @Test("Undecodable lines use JSON-RPC error codes")
    func decodeFailuresUseJSONRPCCodes() throws {
        let parse = router.failure(for: .notJSON)
        #expect(errorCode(in: parse) == ACPErrorCode.parseError.rawValue)
        #expect(parse["id"] is NSNull)

        let object = router.failure(for: .notAnObject)
        #expect(errorCode(in: object) == ACPErrorCode.invalidRequest.rawValue)
        #expect(object["id"] is NSNull)

        let wrongVersion = router.failure(for: .wrongVersion("1.0", id: nil))
        #expect(errorCode(in: wrongVersion) == ACPErrorCode.invalidRequest.rawValue)
        #expect(wrongVersion["id"] is NSNull)

        let missingMethod = router.failure(for: .missingMethod(.string("request")))
        #expect(errorCode(in: missingMethod) == ACPErrorCode.invalidRequest.rawValue)
        #expect(missingMethod["id"] as? String == "request")

        let badParams = router.failure(for: .paramsNotAnObject(.number(7)))
        #expect(errorCode(in: badParams) == ACPErrorCode.invalidParams.rawValue)
        #expect(badParams["id"] as? Int == 7)
    }

    @Test("A wrong version answers the id it could read")
    func wrongVersionKeepsItsIdentifier() throws {
        // JSON-RPC allows a null id in a reply only when the request's id
        // could not be determined, and a bad jsonrpc member does not stop the
        // id from parsing.
        let answered = router.failure(for: .wrongVersion("1.0", id: .number(9)))
        #expect(errorCode(in: answered) == ACPErrorCode.invalidRequest.rawValue)
        #expect(answered["id"] as? Int == 9)
    }

    private enum TestError: Error { case unexpectedOutcome }
}
