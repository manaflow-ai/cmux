@testable import CmuxNextCloud
import Foundation
import Testing

/// The folder menu's Connect to GitHub from the click to the moment GitHub's page opens, against a stub owner API that
/// answers each route after a set latency (the harness for cmuxterm-hq#13940): the menu reads `github.status` when it
/// opens, then the person clicks Connect to GitHub. Each run prints one `github-connect-harness` line with the time and
/// the requests the click sent.
@Suite(.serialized) @MainActor
struct CloudGitHubConnectLatencyTests {
    /// What the stub API is: an API from before the completion link (production on 2026-11-19, which refuses `return_to`
    /// with `validation.invalid`), or one that takes it; a pending connection left from a cancelled install in an earlier
    /// launch; a team policy that refuses every connect.
    struct Scenario: Sendable, CustomStringConvertible {
        var name: String
        var refusesReturnLink = false
        var stalePending = false
        var forbidden = false
        var description: String { name }
    }

    /// Route latencies, one trip each, chosen near what a person on a home connection sees from the owner API:
    /// the status route (it may ask GitHub for the installation's settings page), the `integration.list` read, and
    /// `integration.connect` (a write to the team's ConnectionDO and a signed state); a refusal answers sooner.
    nonisolated static let statusLatency = 0.35, listLatency = 0.25, connectLatency = 0.45, refusalLatency = 0.25

    nonisolated final class StubAPI: URLProtocol, @unchecked Sendable {
        nonisolated(unsafe) static var scenario = Scenario(name: "")
        nonisolated(unsafe) static var sent: [String] = []
        static let lock = NSLock()
        private var cancelled = false

        override class func canInit(with _: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            let body = Self.read(request)
            let path = request.url?.path ?? ""
            let returning = (body["params"] as? [String: Any])?["return_to"] != nil
            Self.lock.withLock { Self.sent.append("\(request.httpMethod ?? "GET") \(path)\(returning ? " +return_to" : "")") }
            let scenario = Self.lock.withLock { Self.scenario }
            let (latency, status, text) = Self.answer(path: path, returning: returning, scenario: scenario)
            DispatchQueue.global().asyncAfter(deadline: .now() + latency) { [self] in
                guard !Self.lock.withLock({ cancelled }), let url = request.url,
                      let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"]) else { return }
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: Data(text.utf8))
                client?.urlProtocolDidFinishLoading(self)
            }
        }

        override func stopLoading() { Self.lock.withLock { cancelled = true } }

        static func answer(path: String, returning: Bool, scenario: Scenario) -> (TimeInterval, Int, String) {
            switch path {
            case "/v1/integrations/github/status":
                return (statusLatency, 200, #"{"configured":true,"app_slug":"cmux","allowed":true,"connection":null}"#)
            case "/v1/read":
                let created = Int(Date().timeIntervalSince1970 * 1000) - 2 * 3600 * 1000
                let rows = scenario.stalePending ? #"[{"id":"conn_old","provider":"github","status":"pending","created_at":\#(created)}]"# : "[]"
                return (listLatency, 200, #"{"ok":true,"value":{"connections":\#(rows),"providers":[{"provider":"github","configured":true}]}}"#)
            case "/v1/ops":
                if scenario.forbidden { return (refusalLatency, 403, #"{"ok":false,"error":{"code":"policy.denied","message":"GitHub is not allowed for this team"}}"#) }
                if returning && scenario.refusesReturnLink {
                    return (refusalLatency, 400, #"{"ok":false,"error":{"code":"validation.invalid","message":"return_to"}}"#)
                }
                return (connectLatency, 200, #"{"ok":true,"value":{"connection":{"id":"conn_new"},"authorize_url":"https://github.com/apps/cmux/installations/new?state=a.eyJleHAiOjQxMDI0NDQ4MDB9.b"}}"#)
            default:
                return (0, 404, "{}")
            }
        }

        static func read(_ request: URLRequest) -> [String: Any] {
            guard let stream = request.httpBodyStream else { return (request.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) }) as? [String: Any] ?? [:] }
            stream.open()
            defer { stream.close() }
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count > 0 else { break }
                data.append(buffer, count: count)
            }
            return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        }
    }

    nonisolated static let team = "team_aaaaaaaaaaaaaaaaaaaa"

    static func client() -> CloudOwnerAPIClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubAPI.self]
        return CloudOwnerAPIClient(baseURL: URL(string: "https://api.invalid")!, accessToken: { "session" }, teamID: { team },
                                   session: URLSession(configuration: configuration))
    }

    /// One click: the menu's status read when it opened, then Connect to GitHub, timed from the click.
    static func click(_ scenario: Scenario) async -> (connect: CloudGitHubPicker.Connect, milliseconds: Int, sent: [String]) {
        StubAPI.lock.withLock { StubAPI.scenario = scenario; StubAPI.sent = [] }
        let client = client(), connects = CloudGitHubConnects()
        _ = await CloudGitHubPicker.status(client: client, team: team, connects: connects)
        StubAPI.lock.withLock { StubAPI.sent = [] }
        let start = ContinuousClock.now
        let connect = await CloudGitHubPicker.connect(client: client, team: team, connects: connects, returnTo: "cmux://integration/complete")
        let elapsed = ContinuousClock.now - start
        let milliseconds = Int(elapsed.components.seconds * 1000 + elapsed.components.attoseconds / 1_000_000_000_000_000)
        let sent = StubAPI.lock.withLock { StubAPI.sent }
        print("github-connect-harness scenario=\(scenario) ms=\(milliseconds) requests=\(sent.count) outcome=\(connect) sent=\(sent)")
        return (connect, milliseconds, sent)
    }

    nonisolated static let scenarios = [
        Scenario(name: "production-api-refuses-return-link", refusesReturnLink: true),
        Scenario(name: "api-takes-return-link"),
        Scenario(name: "stale-pending-from-cancelled-install", stalePending: true),
        Scenario(name: "policy-forbids-connect", forbidden: true),
    ]

    @Test(arguments: scenarios)
    func clickToGitHubsPage(_ scenario: Scenario) async {
        let run = await Self.click(scenario)
        #expect(run.milliseconds >= 0)
    }
}
