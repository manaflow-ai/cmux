import CmuxNextCompat
import CmuxNextDaemonService
import CmuxNextPages
import CmuxNextSettings
import Foundation

/// Serves the Chief view gallery's `cmux.chief_views.*` ops (webviews/src/pages/chief-views/types.ts):
/// - `agents` → every agent row (``ChiefViewsAgent``); stream `agents_changed` → the rows again
///   whenever one changes (Observation, no timer);
/// - `fleet` → the CI dashboard's machines, or `fleet_unavailable` with `details.configured`;
///   `set_fleet_url {url}` names the dashboard (the person's click only);
/// - `landing` → the repository's open and merged-today pull requests (GitHub search, kept 90 s
///   so the views and Refresh stay inside the unauthenticated search limit);
/// - `open {kind, id}` and `open_url {url}` reveal an agent or open a pull request (clicks only).
@MainActor
final class ChiefViewsPageProvider: PageProvider {
    static let prefix = "cmux.chief_views."
    static let agentsOp = prefix + "agents"
    static let agentsChanged = prefix + "agents_changed"
    static let fleetOp = prefix + "fleet"
    static let setFleetURLOp = prefix + "set_fleet_url"
    static let landingOp = prefix + "landing"
    static let openOp = prefix + "open"
    static let openURLOp = prefix + "open_url"
    static let fleetUnavailable = prefix + "fleet_unavailable"
    static let landingUnavailable = prefix + "landing_unavailable"

    /// Where the dashboard's address is kept, and the environment variable that names one first.
    static let fleetURLKey = "cmuxNext.chiefViews.fleetURL"
    static let fleetURLEnvironment = "CMUX_CHIEF_VIEWS_FLEET_URL"
    /// How long one Landing read answers again before GitHub is asked again.
    static let landingLifetime: TimeInterval = 90

    /// What the provider reads and does; the app passes the live ones, tests pass their own.
    struct Host {
        var agents: @MainActor () -> [ChiefViewsAgent]
        /// One GET; throws on a transport error or a status other than 200.
        var fetch: @Sendable (URL) async throws -> Data
        var defaults: UserDefaults
        var environment: [String: String]
        var now: @MainActor () -> Date
        /// Reveals an agent's chat or terminal; throws `ActionFailure` when it is gone.
        var openAgent: @MainActor (ChiefViewsAgent.Kind, String) throws -> Void
        var openURL: @MainActor (URL) -> Void
    }

    private let host: Host
    private var landing: (at: Date, reply: JSONValue)?

    init(host: Host) {
        self.host = host
    }

    func call(_ op: String, params: JSONValue, context: PageCallContext) async throws -> JSONValue {
        switch op {
        case Self.agentsOp:
            return Self.reply(host.agents())
        case Self.fleetOp:
            return try await fleet()
        case Self.setFleetURLOp:
            try Self.requireGesture(context)
            let text = params["url"]?.stringValue ?? ""
            if text.trimmingCharacters(in: .whitespaces).isEmpty {
                host.defaults.removeObject(forKey: Self.fleetURLKey)
                return .object([:])
            }
            guard let url = ChiefViewsFeeds.validFleetURL(text) else { throw PageError.invalidParams("url must be https (http only for localhost or a tailnet .ts.net name)") }
            host.defaults.set(url.absoluteString, forKey: Self.fleetURLKey)
            return .object([:])
        case Self.landingOp:
            return try await landingReply()
        case Self.openOp:
            try Self.requireGesture(context)
            guard let kind = params["kind"]?.stringValue.flatMap(ChiefViewsAgent.Kind.init(rawValue:)),
                  let id = params["id"]?.stringValue, !id.isEmpty else {
                throw PageError.invalidParams("kind (chat or terminal) and id are required")
            }
            try host.openAgent(kind, id)
            return .object([:])
        case Self.openURLOp:
            try Self.requireGesture(context)
            guard let url = params["url"]?.stringValue.flatMap(ChiefViewsFeeds.validPullRequestURL) else {
                throw PageError.invalidParams("url must be a pull request of \(ChiefViewsFeeds.repo)")
            }
            host.openURL(url)
            return .object([:])
        default:
            throw PageError.unknownOp(op)
        }
    }

    func subscribe(_ stream: String, filter: JSONValue, context: PageCallContext,
                   onEvent: @escaping @MainActor (JSONValue) -> Void) async throws -> PageSubscription {
        guard stream == Self.agentsChanged else { throw PageError.unknownOp(stream) }
        let agents = host.agents
        // task-owner: lives as long as the page's subscription; event-driven (Observation)
        let task = Task { @MainActor in
            var last: [ChiefViewsAgent]?
            for await rows in ObservationStream({ agents() }) {
                guard !Task.isCancelled else { return }
                if rows == last { continue }
                // The first value is what the page reads with `agents`; only changes are events.
                if last != nil { onEvent(Self.reply(rows)) }
                last = rows
            }
        }
        // Each event is the whole list: the newest is the page's state.
        return PageSubscription(freezing: .newest) { task.cancel() }
    }

    // MARK: Fleet

    /// The dashboard's address: the environment's, else the one the person set.
    var fleetURL: URL? {
        if let text = host.environment[Self.fleetURLEnvironment], let url = ChiefViewsFeeds.validFleetURL(text) { return url }
        return host.defaults.string(forKey: Self.fleetURLKey).flatMap(ChiefViewsFeeds.validFleetURL)
    }

    private func fleet() async throws -> JSONValue {
        guard let base = fleetURL else {
            throw PageError(code: Self.fleetUnavailable, message: ChiefViewsStrings.fleetUnset, details: ["configured": false])
        }
        let data: Data
        do {
            data = try await host.fetch(ChiefViewsFeeds.fleetDataURL(base))
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw PageError(code: Self.fleetUnavailable, message: ChiefViewsStrings.fleetUnreachable, retryable: true,
                            details: ["configured": true])
        }
        guard let reply = ChiefViewsFeeds.fleetReply(data) else {
            throw PageError(code: Self.fleetUnavailable, message: ChiefViewsStrings.fleetUnreachable, retryable: true,
                            details: ["configured": true])
        }
        return reply
    }

    // MARK: Landing

    private func landingReply() async throws -> JSONValue {
        let now = host.now()
        if let landing, now.timeIntervalSince(landing.at) < Self.landingLifetime { return landing.reply }
        guard let urls = ChiefViewsFeeds.landingSearchURLs(mergedSince: ChiefViewsFeeds.searchDay(now)) else {
            throw PageError(code: Self.landingUnavailable, message: ChiefViewsStrings.landingUnreachable, retryable: true)
        }
        let fetch = host.fetch
        do {
            async let open = fetch(urls.open)
            async let merged = fetch(urls.merged)
            let (openData, mergedData) = try await (open, merged)
            guard let openPRs = ChiefViewsFeeds.landingPRs(openData), let mergedPRs = ChiefViewsFeeds.landingPRs(mergedData) else {
                throw PageError(code: Self.landingUnavailable, message: ChiefViewsStrings.landingUnreachable, retryable: true)
            }
            let reply = ChiefViewsFeeds.landingReply(open: openPRs, merged: mergedPRs)
            landing = (now, reply)
            return reply
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as PageError {
            throw error
        } catch {
            throw PageError(code: Self.landingUnavailable, message: ChiefViewsStrings.landingUnreachable, retryable: true)
        }
    }

    // MARK: Wire

    /// Gesture-only ops: a page can never reveal a tab, open a link or change the dashboard
    /// address on its own.
    private static func requireGesture(_ context: PageCallContext) throws {
        guard context.userGesture || context.isConfirmedUser else {
            throw PageError(code: PageNativeOp.userOnlyCode, message: RefusalStrings.personOnlyFromPage)
        }
    }

    static func reply(_ agents: [ChiefViewsAgent]) -> JSONValue {
        .object(["agents": .array(agents.map(json))])
    }

    static func json(_ agent: ChiefViewsAgent) -> JSONValue {
        func text(_ value: String?) -> JSONValue { value.map(JSONValue.string) ?? .null }
        func ms(_ date: Date?) -> JSONValue { date.map { .number(($0.timeIntervalSince1970 * 1000).rounded()) } ?? .null }
        return .object([
            "id": .string(agent.id),
            "kind": .string(agent.kind.rawValue),
            "name": .string(agent.name),
            "title": .string(agent.title),
            "machine": .string(agent.machine),
            "machineName": text(agent.machineName),
            "folder": text(agent.folder),
            "state": .string(agent.state.rawValue),
            "task": text(agent.task),
            "error": text(agent.error),
            "lastOutputAt": ms(agent.lastOutputAt),
            "since": ms(agent.since),
            "createdAt": ms(agent.createdAt),
            "harness": text(agent.harness),
            "branch": text(agent.branch),
            "parent": text(agent.parent),
        ])
    }

    /// One GET with a short timeout, off the main actor; a status other than 200 throws.
    static let liveFetch: @Sendable (URL) async throws -> Data = { url in
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 8)
        if url.host == "api.github.com" {
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return data
    }
}
