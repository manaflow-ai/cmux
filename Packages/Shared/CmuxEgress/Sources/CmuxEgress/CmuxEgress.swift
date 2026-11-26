import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(os)
import os
#endif
#if canImport(Network)
import Network
#endif
#if canImport(ObjectiveC)
import ObjectiveC
#endif

/// The egress gate for Swift networking (docs/privacy.md, "Egress gate"), the counterpart of the Rust
/// `cmux-egress` crate and with the same rule: a host passes when docs/privacy.md lists it (`EgressHosts`),
/// when the person named it (`allowNamed`), or when it is loopback, an IP literal or a reserved name.
///
/// Make every URLSession with `session(site:...)` or `shared(site:)`, every WebSocket task with `websocket`, every
/// NWConnection with `connection`. `tests/test_egress_gate.py` finds the ones made by hand.
///
/// The mode is `CMUX_EGRESS` (`enforce`, `log`, `off`) when set, else enforce in a debug build and in a nightly
/// (bundle id ending `.nightly` or containing `.nightly.`), else log. Every unlisted host prints one
/// `egress.unlisted host=H site=S mode=M` line to stderr.
///
/// Redirects: the system loads each redirect target through the session's protocol classes again, so the gate
/// checks every hop of every gated session, with or without the caller's own delegate, and a refused hop fails the
/// task with `cannotConnectToHost` like a refused first request.
public struct CmuxEgress {
    public init() {}
    public enum Mode: String, Sendable {
        case enforce, log, off

        public init?(parsing text: String) {
            switch text.trimmingCharacters(in: .whitespaces).lowercased() {
            case "enforce", "1", "on": self = .enforce
            case "log": self = .log
            case "off", "0": self = .off
            default: return nil
            }
        }
    }

    public enum Verdict: Sendable, Equatable {
        case listed, named, local, unlisted
    }

    /// A connection the gate refused.
    public struct Refused: Error, LocalizedError, Sendable, Equatable {
        public let host: String
        public let site: String
        public var errorDescription: String? {
            "egress gate: \(host) is not a host docs/privacy.md lists (from \(site)); list it there with what it receives"
        }
    }

    // MARK: Mode

    /// `CMUX_EGRESS`, else the build's default.
    public static var mode: Mode {
        state.withLock { $0.modeOverride } ?? defaultMode
    }

    /// Sets the mode for the rest of the process (tests). `nil` goes back to the default.
    public static func setMode(_ mode: Mode?) {
        state.withLock { $0.modeOverride = mode }
    }

    private static let defaultMode: Mode = {
        if let text = ProcessInfo.processInfo.environment["CMUX_EGRESS"], let mode = Mode(parsing: text) {
            return mode
        }
        #if DEBUG
        return .enforce
        #else
        let bundleID = Bundle.main.bundleIdentifier ?? ""
        return bundleID.hasSuffix(".nightly") || bundleID.contains(".nightly.") ? .enforce : .log
        #endif
    }()

    // MARK: Verdict

    /// Lets `hostOrURL` through: the person named it in a setting (a self-hosted server's URL, an API endpoint, an
    /// SSH or git host). Never call it with a host from the code or from a server's answer.
    public static func allowNamed(_ hostOrURL: String) {
        let host = hostOf(hostOrURL)
        guard !host.isEmpty else { return }
        state.withLock { _ = $0.named.insert(host) }
    }

    public static func allowNamed(_ url: URL?) {
        if let host = url?.host { allowNamed(host) }
    }

    /// Why `hostOrURL` may be reached, or `.unlisted`.
    public static func verdict(_ hostOrURL: String) -> Verdict {
        let host = hostOf(hostOrURL)
        if isLocal(host) { return .local }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        for pattern in patterns where pattern.count == labels.count {
            if zip(pattern, labels).allSatisfy({ labelMatches($0, $1) }) { return .listed }
        }
        if state.withLock({ $0.named.contains(host) }) { return .named }
        return .unlisted
    }

    /// Checks one connection to `hostOrURL` made for `site`. Throws only in enforce mode.
    public static func check(_ hostOrURL: String, site: String) throws {
        if blocks(hostOrURL, site: site) { throw Refused(host: hostOf(hostOrURL), site: site) }
    }

    /// Whether the connection must be refused: logs an unlisted host once, true only in enforce mode.
    static func blocks(_ hostOrURL: String, site: String) -> Bool {
        let mode = self.mode
        guard mode != .off, verdict(hostOrURL) == .unlisted else { return false }
        let host = hostOf(hostOrURL)
        let first = state.withLock { $0.seen.insert("\(host)|\(site)").inserted }
        if first {
            FileHandle.standardError.write(Data("egress.unlisted host=\(host) site=\(site) mode=\(mode.rawValue)\n".utf8))
        }
        return mode == .enforce
    }

    /// Every (host, site) the gate found unlisted in this process, refused or not.
    public static var unlisted: [String] {
        state.withLock { $0.seen.sorted() }
    }

    // MARK: URLSession

    /// A gated `URLSession(configuration:delegate:delegateQueue:)`.
    public static func session(
        site: String,
        configuration: URLSessionConfiguration = .default,
        delegate: URLSessionDelegate? = nil,
        delegateQueue: OperationQueue? = nil
    ) -> URLSession {
        let copy = (configuration.copy() as? URLSessionConfiguration) ?? configuration
        copy.protocolClasses = [gateClass(site: site)] + (copy.protocolClasses ?? [])
        return URLSession(
            configuration: copy,
            delegate: delegate,
            delegateQueue: delegateQueue
        )
    }

    /// A gated stand-in for `URLSession.shared`: the default configuration, so the shared cookie and cache storage,
    /// one session per site.
    public static func shared(site: String) -> URLSession {
        if let existing = state.withLock({ $0.shared[site] }) { return existing }
        let made = session(site: site)
        return state.withLock { (state: inout Values) -> URLSession in
            if let existing = state.shared[site] { return existing }
            state.shared[site] = made
            return made
        }
    }

    /// ``shared(site:)`` for a URL the person picked in the moment (an image they copy, a link they open): its host
    /// is let through as ``allowNamed(_:)`` would. Never call it with a URL from the code or a server's answer.
    public static func named(_ url: URL, site: String) -> URLSession {
        allowNamed(url)
        return shared(site: site)
    }

    // MARK: WebSocket

    private static let refusedURL = URL(string: "ws://127.0.0.1:1/egress-refused") ?? URL(fileURLWithPath: "/")

    /// A gated `session.webSocketTask(with:)`. Where the gate refuses (enforce mode) the task is aimed at a closed
    /// loopback port, so it fails when resumed, after the `egress.unlisted` line names the host.
    public static func websocket(_ session: URLSession, with url: URL, site: String) -> URLSessionWebSocketTask {
        if blocks(url.absoluteString, site: site) {
            return session.webSocketTask(with: refusedURL)
        }
        return session.webSocketTask(with: url)
    }

    public static func websocket(_ session: URLSession, with request: URLRequest, site: String) -> URLSessionWebSocketTask {
        if let url = request.url, blocks(url.absoluteString, site: site) {
            return session.webSocketTask(with: refusedURL)
        }
        return session.webSocketTask(with: request)
    }

    // MARK: NWConnection

    #if canImport(Network)
    /// A gated `NWConnection(host:port:using:)`. Refused (enforce mode): aimed at a closed loopback port.
    public static func connection(
        host: NWEndpoint.Host,
        port: NWEndpoint.Port,
        using parameters: NWParameters,
        site: String
    ) -> NWConnection {
        connection(to: .hostPort(host: host, port: port), using: parameters, site: site)
    }

    /// A gated `NWConnection(to:using:)`.
    public static func connection(to endpoint: NWEndpoint, using parameters: NWParameters, site: String) -> NWConnection {
        if let host = hostName(of: endpoint), blocks(host, site: site) {
            return NWConnection(host: "127.0.0.1", port: 1, using: parameters)
        }
        return NWConnection(to: endpoint, using: parameters)
    }

    /// The name an endpoint resolves by; `nil` for addresses, unix sockets and Bonjour services.
    static func hostName(of endpoint: NWEndpoint) -> String? {
        switch endpoint {
        case .hostPort(let host, _):
            if case .name(let name, _) = host { return name }
            return nil
        case .url(let url):
            return url.host
        default:
            return nil
        }
    }
    #endif

    // MARK: Matching (the same rules as cmux-egress/src/lib.rs)

    private static let patterns: [[String]] = EgressHosts.patterns.map {
        $0.lowercased().split(separator: ".", omittingEmptySubsequences: false).map(String.init)
    }

    /// The lower-cased host of a URL or bare host name, without port or trailing dot.
    static func hostOf(_ text: String) -> String {
        var rest = Substring(text.trimmingCharacters(in: .whitespacesAndNewlines))
        if let range = rest.range(of: "://") { rest = rest[range.upperBound...] }
        var authority = rest.prefix { !"/?#".contains($0) }
        if let at = authority.lastIndex(of: "@") { authority = authority[authority.index(after: at)...] }
        var host = authority
        if authority.hasPrefix("[") {
            host = authority.dropFirst().prefix { $0 != "]" }
        } else if let colon = authority.lastIndex(of: ":"), authority.firstIndex(of: ":") == colon,
                  authority[authority.index(after: colon)...].allSatisfy(\.isASCIIDigit) {
            host = authority[..<colon]
        }
        while host.hasSuffix(".") { host = host.dropLast() }
        return host.lowercased()
    }

    /// Whether `label` matches `pattern`, where each `*` stands for one or more characters.
    static func labelMatches(_ pattern: String, _ label: String) -> Bool {
        func glob(_ p: ArraySlice<Character>, _ l: ArraySlice<Character>) -> Bool {
            guard let first = p.first else { return l.isEmpty }
            if first == "*" {
                let rest = p.dropFirst()
                return (1...max(l.count, 1)).contains { n in n <= l.count && glob(rest, l.dropFirst(n)) }
            }
            guard let head = l.first, head == first else { return false }
            return glob(p.dropFirst(), l.dropFirst())
        }
        return glob(ArraySlice(pattern), ArraySlice(label))
    }

    static func isLocal(_ host: String) -> Bool {
        if host.isEmpty || host == "localhost" || host == "example.com" || host.hasSuffix(".example.com") { return true }
        // A name with no dot is a machine on the person's own network (`mac-mini`, `devbox`).
        if !host.contains(".") { return true }
        let privateSuffixes = [".localhost", ".test", ".example", ".invalid", ".local", ".home.arpa", ".ts.net", ".internal", ".lan"]
        if privateSuffixes.contains(where: host.hasSuffix) {
            return true
        }
        return isIPLiteral(host)
    }

    private static func isIPLiteral(_ host: String) -> Bool {
        var v4 = in_addr()
        var v6 = in6_addr()
        return inet_pton(AF_INET, host, &v4) == 1 || inet_pton(AF_INET6, host, &v6) == 1
    }

    // MARK: State

    private struct Values: Sendable {
        var modeOverride: Mode?
        /// Seeded with the hosts the person's own `CMUX_*_URL`, `_ORIGIN`, `_BASE`, `_HOST` and `_ENDPOINT`
        /// environment variables name (a dev server, a staging API): the person set them, the code did not.
        var named: Set<String> = CmuxEgress.namedByEnvironment(ProcessInfo.processInfo.environment)
        var seen: Set<String> = []
        var shared: [String: URLSession] = [:]
    }

    private static let state = OSAllocatedUnfairLock(initialState: Values())

    static func namedByEnvironment(_ environment: [String: String]) -> Set<String> {
        var hosts: Set<String> = []
        for (key, value) in environment where key.hasPrefix("CMUX_") {
            guard ["_URL", "_ORIGIN", "_BASE", "_HOST", "_ENDPOINT"].contains(where: key.hasSuffix) else { continue }
            for part in value.split(separator: ",") {
                let host = hostOf(String(part))
                if !host.isEmpty { hosts.insert(host) }
            }
        }
        return hosts
    }

    // MARK: The URLProtocol

    /// Claims (and fails) a request whose host the gate refuses; every other request falls through to the system's
    /// own handling, so listed hosts keep their full URLSession behaviour. One subclass per site, named
    /// `CmuxEgressGate.<site>`, tells the class which site it was made for.
    class GateProtocol: URLProtocol {
        static let namePrefix = "CmuxEgressGate."

        static var site: String {
            #if canImport(ObjectiveC)
            let name = NSStringFromClass(self)
            #else
            let name = String(reflecting: self)
            #endif
            return name.hasPrefix(namePrefix) ? String(name.dropFirst(namePrefix.count)) : "urlsession"
        }

        override class func canInit(with request: URLRequest) -> Bool {
            guard let url = request.url, let scheme = url.scheme?.lowercased(),
                  ["http", "https", "ws", "wss"].contains(scheme), let host = url.host else { return false }
            return CmuxEgress.blocks(host, site: site)
        }

        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            let host = request.url?.host ?? ""
            let refused = Refused(host: host, site: Self.site)
            client?.urlProtocol(self, didFailWithError: URLError(
                .cannotConnectToHost,
                userInfo: [NSLocalizedDescriptionKey: refused.errorDescription ?? "egress gate refused \(host)"]
            ))
        }

        override func stopLoading() {}
    }

    private static func gateClass(site: String) -> AnyClass {
        #if canImport(ObjectiveC)
        let name = GateProtocol.namePrefix + site
        // Under the state lock, so two first sessions for one site never race between allocate and register.
        state.withLock { _ in
            guard NSClassFromString(name) == nil, let made = objc_allocateClassPair(GateProtocol.self, name, 0) else { return }
            objc_registerClassPair(made)
        }
        return NSClassFromString(name) ?? GateProtocol.self
        #else
        return GateProtocol.self
        #endif
    }
}

private extension Character {
    var isASCIIDigit: Bool { isASCII && isNumber }
}
