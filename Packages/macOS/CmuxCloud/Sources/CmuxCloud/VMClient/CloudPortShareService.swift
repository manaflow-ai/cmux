import Foundation

/// The publication calls Share needs, scoped to the machine's owning team.
/// `VMClient` is the live implementation; tests use a fake.
public protocol CloudPortPublishing: Sendable {
    func listPublications(scopeTeamID: String?) async throws -> [VMPublication]
    func createDefaultPublication(vmID: String, port: Int, scopeTeamID: String?) async throws -> VMPublication
    func verifyPublication(id: String, scopeTeamID: String?) async throws -> VMPublication
    func deletePublication(id: String, scopeTeamID: String?) async throws
}

extension VMClient: CloudPortPublishing {
    /// No access mode and no team: the server picks team access for a team
    /// machine and owner-only access for a personal one.
    public func createDefaultPublication(vmID: String, port: Int, scopeTeamID: String?) async throws -> VMPublication {
        try await createPublication(
            vmID: vmID,
            port: port,
            hostname: nil,
            accessMode: nil,
            teamID: nil,
            scopeTeamID: scopeTeamID
        )
    }
}

public enum CloudPortShareError: Error, Equatable, Sendable {
    /// The link exists but its route never became ready within the wait.
    case stillProvisioning
    /// The service reports the publication can't serve (for example `unavailable`).
    case unavailable(state: String)
}

/// Finds or creates the shareable link for one machine port, and waits until
/// it serves before handing it back, so a copied link is never a dead one.
public struct CloudPortShareService: Sendable {
    public typealias Sleep = @Sendable (Duration) async throws -> Void
    /// Opens the link once as a signed-out visitor and returns the HTTP
    /// status, or nil when the edge could not be reached.
    public typealias Probe = @Sendable (URL) async -> Int?

    /// Waits between readiness checks. Creation provisions the route right
    /// away; the wait only covers the edge certificate catching up.
    public static let defaultPollDelays: [Duration] = [
        .seconds(1), .seconds(2), .seconds(3), .seconds(5), .seconds(5),
        .seconds(10), .seconds(10), .seconds(15), .seconds(15), .seconds(15),
        .seconds(15), .seconds(15),
    ]

    private let api: any CloudPortPublishing
    private let pollDelays: [Duration]
    private let sleep: Sleep
    private let probe: Probe

    public init(
        api: any CloudPortPublishing,
        pollDelays: [Duration] = CloudPortShareService.defaultPollDelays,
        sleep: @escaping Sleep = { try await Task.sleep(for: $0) },
        probe: @escaping Probe = CloudPortShareService.signedOutStatus
    ) {
        self.api = api
        self.pollDelays = pollDelays
        self.sleep = sleep
        self.probe = probe
    }

    /// The live publication for this port, if there is one.
    public func existing(vmID: String, port: Int, teamID: String?) async throws -> VMPublication? {
        try await api.listPublications(scopeTeamID: teamID).first {
            $0.vmID == vmID && $0.port == port && Self.isLive($0.state)
        }
    }

    /// Reuses the port's publication (whatever its access) or creates one with
    /// the server's default access, then waits until the link itself answers:
    /// `active` on the server can run ahead of the edge, which shows a 503
    /// page until its authorization check and route are ready.
    public func share(vmID: String, port: Int, teamID: String?) async throws -> VMPublication {
        var publication: VMPublication
        if let found = try await existing(vmID: vmID, port: port, teamID: teamID) {
            publication = found
        } else {
            publication = try await api.createDefaultPublication(vmID: vmID, port: port, scopeTeamID: teamID)
        }
        var delays = pollDelays.makeIterator()
        while true {
            switch publication.state {
            case "active":
                if let url = URL(string: publication.url), let status = await probe(url), status < 500 {
                    return publication
                }
                guard let delay = delays.next() else { throw CloudPortShareError.stillProvisioning }
                try await sleep(delay)
            case "provisioning":
                guard let delay = delays.next() else { throw CloudPortShareError.stillProvisioning }
                try await sleep(delay)
                publication = try await api.verifyPublication(id: publication.id, scopeTeamID: teamID)
            default:
                throw CloudPortShareError.unavailable(state: publication.state)
            }
        }
    }

    /// Unpublishes the port. Its link stops working on the next request.
    public func stopSharing(publicationID: String, teamID: String?) async throws {
        try await api.deletePublication(id: publicationID, scopeTeamID: teamID)
    }

    /// A signed-out GET that doesn't follow redirects: a protected link answers
    /// with its sign-in redirect (302) or 401/403, a public one with the app.
    public static let signedOutStatus: Probe = { url in
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        let session = URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        guard let (_, response) = try? await session.data(for: request) else { return nil }
        return (response as? HTTPURLResponse)?.statusCode
    }

    /// `disabling` and `disabled` rows are on their way out and can't be reused.
    private static func isLive(_ state: String) -> Bool {
        state != "disabling" && state != "disabled"
    }
}

private final class NoRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest
    ) async -> URLRequest? {
        nil
    }
}
