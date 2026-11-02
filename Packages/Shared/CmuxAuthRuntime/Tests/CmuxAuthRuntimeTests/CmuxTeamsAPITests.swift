import CMUXAuthCore
import Foundation
import Testing
@testable import CmuxAuthRuntime

/// The cmux team API client over a URL session whose transport answers like
/// `web/app/api/teams`: the request each call sends (method, path, the
/// native session headers, the body) and how each server refusal maps to a
/// ``CMUXTeamError`` the UI can explain.
@Suite(.serialized) struct CmuxTeamsAPITests {
    @Test func listingSendsTheSessionPairAndReadsRoles() async throws {
        let stub = TeamsStub.make()
        stub.answer("GET /api/teams", 200, """
        {"teams":[
          {"id":"t1","displayName":"Acme","profileImageUrl":null,"role":"admin",
           "permissions":{"updateTeam":true,"deleteTeam":true,"inviteMembers":true,"readMembers":true,"removeMembers":true,"manageApiKeys":true,"manageBilling":true}},
          {"id":"t2","displayName":"Research","profileImageUrl":null,"role":"member",
           "permissions":{"updateTeam":false,"deleteTeam":false,"inviteMembers":false,"readMembers":true,"removeMembers":false,"manageApiKeys":false,"manageBilling":false}}
        ],"selectedTeamId":"t2"}
        """)

        let list = try await stub.api.memberships()

        #expect(list.teams.map(\.displayName) == ["Acme", "Research"])
        #expect(list.teams.map(\.role) == [.admin, .member])
        #expect(list.teams.map(\.canDelete) == [true, false])
        #expect(list.selectedTeamID == "t2")
        let request = try #require(stub.requests.first)
        #expect(request.header("Authorization") == "Bearer access-token")
        #expect(request.header("X-Stack-Refresh-Token") == "refresh-token")
    }

    @Test func detailReadsMembersInvitationsAndBilling() async throws {
        let stub = TeamsStub.make()
        stub.answer("GET /api/teams/t1", 200, """
        {"team":{"id":"t1","displayName":"Acme","profileImageUrl":null},
         "viewer":{"userId":"u1","role":"admin","permissions":{"updateTeam":true,"deleteTeam":true}},
         "members":[
           {"userId":"u1","displayName":"Sam","email":"sam@example.com","profileImageUrl":null,"role":"admin","isViewer":true},
           {"userId":"u2","displayName":null,"email":"lee@example.com","profileImageUrl":null,"role":"member","isViewer":false}],
         "invitations":[{"id":"i1","email":"kim@example.com","role":"member","expiresAt":"2026-11-02T10:00:00.000Z"}],
         "links":[],
         "billing":{"planId":"team","seats":5,"memberLimit":null,"memberCount":2,"hasActiveSubscription":true}}
        """)

        let detail = try await stub.api.detail(teamID: "t1")

        #expect(detail.viewer.role == .admin)
        #expect(detail.viewer.permissions.deleteTeam)
        #expect(!detail.viewer.permissions.manageBilling) // not sent: not granted
        #expect(detail.members.map(\.isViewer) == [true, false])
        #expect(detail.members.last?.displayName == nil)
        #expect(detail.invitations.map(\.email) == ["kim@example.com"])
        #expect(detail.billing?.planId == "team")
        #expect(detail.billing?.hasActiveSubscription == true)
    }

    @Test func createAndRenameSendTheTrimmedName() async throws {
        let stub = TeamsStub.make()
        stub.answer("POST /api/teams", 201, #"{"team":{"id":"t9","displayName":"New Team"}}"#)
        stub.answer("PATCH /api/teams/t9", 200, #"{"team":{"id":"t9","displayName":"Renamed","profileImageUrl":null}}"#)

        let created = try await stub.api.create(displayName: "  New Team ")
        let renamed = try await stub.api.rename(teamID: "t9", displayName: "Renamed\n")

        #expect(created == CMUXAuthTeam(id: "t9", displayName: "New Team"))
        #expect(renamed.displayName == "Renamed")
        #expect(stub.requests.map(\.line) == ["POST /api/teams", "PATCH /api/teams/t9"])
        #expect(stub.requests.map(\.bodyText) == [#"{"displayName":"New Team"}"#, #"{"displayName":"Renamed"}"#])
    }

    /// Invite to Team (Home's dialog, `home.inviteToTeam`): one POST with the addresses and the
    /// role, and the server's sent and refused addresses read back.
    @Test func inviteSendsTheAddressesAndReadsSentAndRefused() async throws {
        let stub = TeamsStub.make()
        stub.answer("POST /api/teams/t1/invitations", 200, """
        {"invitations":[{"id":"i1","email":"leo@cmux.com","role":"member","expiresAt":"2026-11-05T10:00:00.000Z"}],
         "failed":[{"email":"sam@example.com","code":"already_member"}]}
        """)

        let result = try await stub.api.invite(teamID: "t1", emails: ["leo@cmux.com", "sam@example.com"])

        #expect(stub.requests.map(\.line) == ["POST /api/teams/t1/invitations"])
        let body = try JSONSerialization.jsonObject(with: Data(try #require(stub.requests.first).bodyText.utf8)) as? [String: Any]
        #expect(body?["emails"] as? [String] == ["leo@cmux.com", "sam@example.com"])
        #expect(body?["role"] as? String == "member")
        #expect(body?.count == 2, "the server's schema is strict: no other key")
        #expect(result.invitations.map(\.email) == ["leo@cmux.com"])
        #expect(result.failed == [.init(email: "sam@example.com", code: "already_member")])
        #expect(result.failed.first?.isAlreadyMember == true)
    }

    @Test func aNameOutOfRangeSendsNothing() async throws {
        let stub = TeamsStub.make()

        await #expect(throws: CMUXTeamError.invalidName) { _ = try await stub.api.create(displayName: " \n ") }
        // The API checks the server's own limit (120); the Mac's forms keep theirs (64).
        await #expect(throws: CMUXTeamError.invalidName) {
            _ = try await stub.api.rename(teamID: "t1", displayName: String(repeating: "a", count: CMUXTeamName.serverMaximumLength + 1))
        }
        #expect(stub.requests.isEmpty)
    }

    @Test func serverRefusalsBecomeTypedErrors() async throws {
        let cases: [(status: Int, body: String, expected: CMUXTeamError)] = [
            (409, #"{"error":{"code":"team_has_active_subscription","message":"Cancel the team subscription before deleting the team."}}"#, .subscriptionActive),
            (403, #"{"error":{"code":"forbidden","message":"You do not have permission to do this."}}"#, .forbidden),
            (403, #"{"error":{"code":"team_not_found","message":"Team not found."}}"#, .notFound),
            (404, "", .notFound),
            (401, #"{"error":{"code":"unauthorized","message":"Sign in to continue."}}"#, .signedOut),
            (503, #"{"error":{"code":"service_unavailable","message":"x"}}"#, .unavailable),
            (500, "<html>", .unavailable),
        ]
        for (status, body, expected) in cases {
            let stub = TeamsStub.make()
            stub.answer("DELETE /api/teams/t1", status, body)
            await #expect(throws: expected) { try await stub.api.delete(teamID: "t1") }
        }
    }

    @Test func aMalformedReplyIsUnavailable() async throws {
        let stub = TeamsStub.make()
        stub.answer("GET /api/teams", 200, #"{"unexpected":true}"#)

        await #expect(throws: CMUXTeamError.unavailable) { _ = try await stub.api.memberships() }
    }

    @Test func noSessionSendsNothing() async throws {
        let stub = TeamsStub.make(signedIn: false)

        await #expect(throws: CMUXTeamError.signedOut) { _ = try await stub.api.memberships() }
        #expect(stub.requests.isEmpty)
    }
}

/// One test's transport: scripted replies by `METHOD /path` on a host of its
/// own, and every request it saw.
final class TeamsStub: @unchecked Sendable {
    struct Request {
        let line: String
        let headers: [String: String]
        let bodyText: String

        func header(_ name: String) -> String? {
            headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
        }
    }

    let host: String
    let api: CmuxTeamsAPI
    private let lock = NSLock()
    private var replies: [String: (Int, String)] = [:]
    private var seen: [Request] = []

    private init(signedIn: Bool) {
        let host = "teams-\(UUID().uuidString.lowercased()).test"
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TeamsStubProtocol.self]
        self.host = host
        api = CmuxTeamsAPI(baseURL: URL(string: "https://\(host)") ?? URL(fileURLWithPath: "/"),
                           session: URLSession(configuration: configuration)) {
            signedIn ? (access: "access-token", refresh: "refresh-token") : nil
        }
    }

    static func make(signedIn: Bool = true) -> TeamsStub {
        let stub = TeamsStub(signedIn: signedIn)
        TeamsStubProtocol.register(stub)
        return stub
    }

    var requests: [Request] { lock.withLock { seen } }

    func answer(_ line: String, _ status: Int, _ body: String) {
        lock.withLock { replies[line] = (status, body) }
    }

    fileprivate func reply(to request: URLRequest) -> (Int, Data) {
        let line = "\(request.httpMethod ?? "GET") \(request.url?.path ?? "")"
        let body = Self.body(of: request)
        return lock.withLock {
            seen.append(Request(line: line, headers: request.allHTTPHeaderFields ?? [:], bodyText: String(decoding: body, as: UTF8.self)))
            let (status, text) = replies[line] ?? (404, "")
            return (status, Data(text.utf8))
        }
    }

    /// URL loading moves a body into a stream before a protocol sees it.
    private static func body(of request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

final class TeamsStubProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var stubs: [String: TeamsStub] = [:]

    static func register(_ stub: TeamsStub) {
        lock.withLock { stubs[stub.host] = stub }
    }

    private static func stub(for host: String?) -> TeamsStub? {
        lock.withLock { host.flatMap { stubs[$0] } }
    }

    override class func canInit(with request: URLRequest) -> Bool { stub(for: request.url?.host) != nil }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let stub = Self.stub(for: url.host) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let (status, body) = stub.reply(to: request)
        guard let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1",
                                             headerFields: ["Content-Type": "application/json"]) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
