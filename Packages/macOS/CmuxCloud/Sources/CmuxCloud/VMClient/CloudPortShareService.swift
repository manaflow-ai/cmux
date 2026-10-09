import Foundation

/// The publication calls Share needs, scoped to the machine's owning team.
/// `VMClient` is the live implementation; tests use a fake.
public protocol CloudPortPublishing: Sendable {
    func listPublications(scopeTeamID: String?) async throws -> [VMPublication]
    func createDefaultPublication(vmID: String, port: Int, scopeTeamID: String?) async throws -> VMPublication
    func deletePublication(id: String, scopeTeamID: String?) async throws
}

extension VMClient: CloudPortPublishing {
    /// No access mode and no team: the server picks team access for a team
    /// machine and owner-only access for a personal one. Repeating it is safe:
    /// the generated hostname is fixed per machine and port, so the server
    /// returns the existing row and resumes provisioning it, including a row a
    /// teammate created.
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
    /// The link exists but did not start serving within the wait.
    case stillProvisioning
}

/// Finds or creates the shareable link for one machine port, and waits until
/// it serves before handing it back, so a copied link is never a dead one.
///
/// The wait polls because the service has no push channel for publication
/// readiness; the delays and the sleep are injected so tests run without real
/// time.
public struct CloudPortShareService: Sendable {
    public typealias Sleep = @Sendable (Duration) async throws -> Void
    /// Asks the link once, signed out, whether the edge can serve it, and
    /// returns the HTTP status, or nil when the edge could not be reached.
    public typealias Probe = @Sendable (URL) async -> Int?

    /// Waits between readiness checks, about a minute in total. Creation
    /// provisions the route right away; the wait covers the edge catching up.
    public static let defaultPollDelays: [Duration] = [
        .seconds(1), .seconds(2), .seconds(3), .seconds(4), .seconds(5),
        .seconds(5), .seconds(10), .seconds(10), .seconds(10), .seconds(10),
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

    /// The live cmux-generated link for this port, if there is one. A custom
    /// domain on the same port is left alone: it may still be waiting on the
    /// user's DNS, and it isn't the link Share hands out.
    public func existing(vmID: String, port: Int, teamID: String?) async throws -> VMPublication? {
        try await api.listPublications(scopeTeamID: teamID).first {
            $0.vmID == vmID && $0.port == port && $0.domainKind == "generated" && Self.isLive($0.state)
        }
    }

    /// Reuses the port's generated link (whatever its access) or creates one
    /// with the server's default access, then waits until the link itself
    /// answers: `active` on the server can run ahead of the edge, which shows
    /// a 503 page until its authorization check and route are ready.
    public func share(vmID: String, port: Int, teamID: String?) async throws -> VMPublication {
        var delays = pollDelays.makeIterator()
        var publication = try await existing(vmID: vmID, port: port, teamID: teamID)
        while true {
            if publication?.state != "active" {
                // Creating again resumes a provisioning or unavailable row. A
                // row still being removed (409) or a busy provisioning lease
                // (503) only means "not yet".
                do {
                    publication = try await api.createDefaultPublication(vmID: vmID, port: port, scopeTeamID: teamID)
                } catch VMClientError.httpStatus(let status, _) where status == 409 || status == 503 {
                    publication = nil
                }
            }
            if let current = publication, current.state == "active", await serves(current) {
                return current
            }
            guard let delay = delays.next() else { throw CloudPortShareError.stillProvisioning }
            try await sleep(delay)
        }
    }

    /// Unpublishes the port. Its link stops working on the next request.
    public func stopSharing(publicationID: String, teamID: String?) async throws {
        try await api.deletePublication(id: publicationID, scopeTeamID: teamID)
    }

    /// A public link would send the probe to the user's app, so it is taken as
    /// is. A protected link must answer the signed-out probe the way cmux's
    /// authorization check does (401), or serve or redirect; anything else,
    /// such as the edge's 503 or a 404 for a route it doesn't know yet, waits.
    private func serves(_ publication: VMPublication) async -> Bool {
        guard publication.accessMode != .public else { return true }
        guard let url = URL(string: publication.url), let status = await probe(url) else { return false }
        return (200..<400).contains(status) || status == 401
    }

    /// A signed-out HEAD to a protected link. cmux's authorization check
    /// answers it with 401 without starting a sign-in or reaching the machine.
    /// HEAD stays safe if a protected publication becomes public while the
    /// request is in flight: the edge can forward it to the user's app, but
    /// it cannot carry a request body or trigger a POST mutation.
    public static let signedOutStatus: Probe = { url in
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 5
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        let session = URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
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
