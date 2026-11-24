// The Swift egress gate (docs/privacy.md, "Egress gate"); the Rust one is cmux-tui/crates/cmux-egress.
//
// docs/privacy.md lists every host the apps connect to (its `connects` rows); `EgressHosts.listed` is that
// list, generated from the doc and kept equal to it by tests/test_egress_gate.py. Every URLSession,
// WebSocket and NWConnection the apps open for themselves is made here:
//
// - `Egress.session(site:configuration:delegate:delegateQueue:)` and `Egress.shared` put `EgressURLProtocol`
//   first in the session's protocol classes, so every request the session loads, a redirect's new request
//   included, is checked before it is sent;
// - `Egress.webSocketTask(in:with:site:)` checks the URL before the socket opens (URLSession hands WebSockets
//   to no URLProtocol);
// - `Egress.connection(to:using:site:)` checks an NWConnection's host before it is made.
//
// Passes, besides the listed hosts: hosts the person named in a setting or opened themselves
// (`Egress.allowNamed`), loopback, IP literals and reserved names (`localhost`, `.test`, `.example`,
// `.invalid`, `.local`, `.home.arpa`).
//
// `Egress.Mode.enforce` refuses the rest; `.log` only reports it. The mode is `CMUX_EGRESS` (`enforce`, `log`
// or `off`) when set, else enforce in a DEBUG build and log in a release build. Each refusal (or would-be
// refusal) prints one `egress.unlisted host=H site=S mode=M` line, once per host and site.

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(Network)
import Network
#endif

public enum Egress {
    /// The environment variable that picks the mode.
    public static let modeEnvironment = "CMUX_EGRESS"

    public enum Mode: String, Sendable {
        /// Refuse an unlisted host.
        case enforce
        /// Report an unlisted host and let it through.
        case log
        /// Check nothing.
        case off

        public init?(parsing text: String) {
            switch text.trimmingCharacters(in: .whitespaces).lowercased() {
            case "enforce", "1", "on": self = .enforce
            case "log": self = .log
            case "off", "0": self = .off
            default: return nil
            }
        }
    }

    /// Why a host may be reached.
    public enum Verdict: Sendable, Equatable {
        /// docs/privacy.md lists it.
        case listed
        /// The person named it (`allowNamed`).
        case named
        /// Loopback, an IP literal or a reserved name.
        case local
        /// None of the above.
        case unlisted
    }

    /// A connection the gate refused.
    public struct Refused: Error, CustomStringConvertible, Sendable, Equatable {
        public let host: String
        public let site: String

        public var description: String {
            "egress gate: \(host) is not a host docs/privacy.md lists (from \(site)); list it there with what it receives"
        }
    }

    // MARK: State

    private final class State: @unchecked Sendable {
        let lock = NSLock()
        var mode: Mode?
        var named: Set<String> = []
        var seen: Set<String> = []
    }

    private static let state = State()

    private static let defaultMode: Mode = {
        #if DEBUG
        return .enforce
        #else
        return .log
        #endif
    }()

    /// This process's mode: `setMode`'s, else `CMUX_EGRESS`'s, else the build's default.
    public static var mode: Mode {
        state.lock.lock()
        defer { state.lock.unlock() }
        if let mode = state.mode { return mode }
        let mode = ProcessInfo.processInfo.environment[modeEnvironment].flatMap(Mode.init(parsing:)) ?? defaultMode
        state.mode = mode
        return mode
    }

    /// Sets the mode for the rest of the process (the app's start for nightly, tests).
    public static func setMode(_ mode: Mode) {
        state.lock.lock()
        state.mode = mode
        state.lock.unlock()
    }

    /// Lets `hostOrURL`'s host through: the person named it in a setting (a self-hosted server, an API
    /// endpoint) or opened it themselves (a page in the browser, a link they clicked). Never call it with a
    /// host from the code or from a server's answer.
    public static func allowNamed(_ hostOrURL: String) {
        let host = hostOf(hostOrURL)
        guard !host.isEmpty else { return }
        state.lock.lock()
        state.named.insert(host)
        state.lock.unlock()
    }

    /// `allowNamed` for a URL; nil does nothing.
    public static func allowNamed(_ url: URL?) {
        if let host = url?.host { allowNamed(host) }
    }

    /// Every "host site" the gate found unlisted in this process, refused or not.
    public static var unlisted: [String] {
        state.lock.lock()
        defer { state.lock.unlock() }
        return state.seen.sorted()
    }

    // MARK: Verdict

    /// The lower-cased host of a URL or bare host name, without port, brackets or trailing dot.
    static func hostOf(_ text: String) -> String {
        var rest = Substring(text.trimmingCharacters(in: .whitespaces))
        if let scheme = rest.range(of: "://") { rest = rest[scheme.upperBound...] }
        var authority = rest.prefix { $0 != "/" && $0 != "?" && $0 != "#" }
        if let at = authority.lastIndex(of: "@") { authority = authority[authority.index(after: at)...] }
        var host: Substring
        if authority.hasPrefix("[") {
            host = authority.dropFirst().prefix { $0 != "]" }
        } else if let colon = authority.lastIndex(of: ":"),
                  authority[authority.index(after: colon)...].allSatisfy(\.isNumber),
                  authority.firstIndex(of: ":") == colon {
            host = authority[..<colon]
        } else {
            host = authority
        }
        while host.hasSuffix(".") { host = host.dropLast() }
        return host.lowercased()
    }

    /// Whether `label` matches `pattern`, where each `*` stands for one or more characters.
    static func labelMatches(_ pattern: Substring, _ label: Substring) -> Bool {
        guard let first = pattern.first else { return label.isEmpty }
        if first == "*" {
            let rest = pattern.dropFirst()
            var tail = label
            while !tail.isEmpty {
                tail = tail.dropFirst()
                if labelMatches(rest, tail) { return true }
            }
            return false
        }
        guard let head = label.first, head == first else { return false }
        return labelMatches(pattern.dropFirst(), label.dropFirst())
    }

    static func isIPLiteral(_ host: String) -> Bool {
        var v4 = in_addr()
        var v6 = in6_addr()
        return host.withCString { inet_pton(AF_INET, $0, &v4) == 1 || inet_pton(AF_INET6, $0, &v6) == 1 }
    }

    static func isLocal(_ host: String) -> Bool {
        isIPLiteral(host)
            || host == "localhost"
            || [".localhost", ".test", ".example", ".invalid", ".local", ".home.arpa"].contains { host.hasSuffix($0) }
            || host == "example.com"
            || host.hasSuffix(".example.com")
    }

    private static let listedPatterns: [[Substring]] = EgressHosts.listed.map { $0.lowercased().split(separator: ".") }

    /// Why `hostOrURL` may be reached, or `.unlisted`.
    public static func verdict(_ hostOrURL: String) -> Verdict {
        let host = hostOf(hostOrURL)
        if host.isEmpty || isLocal(host) { return .local }
        let labels = Substring(host).split(separator: ".", omittingEmptySubsequences: false)
        let hit = listedPatterns.contains { pattern in
            pattern.count == labels.count && zip(pattern, labels).allSatisfy { labelMatches($0, $1) }
        }
        if hit { return .listed }
        state.lock.lock()
        defer { state.lock.unlock() }
        return state.named.contains(host) ? .named : .unlisted
    }

    /// Checks one connection to `hostOrURL` made for `site` (the caller, as `Module.Type`). Throws only in
    /// `.enforce`.
    public static func check(_ hostOrURL: String, site: String) throws(Refused) {
        let mode = mode
        guard mode != .off, verdict(hostOrURL) == .unlisted else { return }
        let host = hostOf(hostOrURL)
        state.lock.lock()
        let first = state.seen.insert("\(host) \(site)").inserted
        state.lock.unlock()
        if first {
            FileHandle.standardError.write(Data("egress.unlisted host=\(host) site=\(site) mode=\(mode.rawValue)\n".utf8))
        }
        if mode == .enforce { throw Refused(host: host, site: site) }
    }

    /// `check` for a URL: a URL with no host (a file, a data URL) passes.
    public static func check(_ url: URL?, site: String) throws(Refused) {
        guard let url, let host = url.host, !host.isEmpty else { return }
        try check(host, site: site)
    }

    // MARK: URLSession

    /// A session whose every request passes the gate. `site` names the caller; a URLProtocol sees only the
    /// request, so its refusal line reads `site=URLSession` and `site` is kept for the call site's record
    /// (tests/test_egress_gate.py reads it). Nothing is added to the request.
    public static func session(
        site: String,
        configuration: URLSessionConfiguration = .default,
        delegate: (any URLSessionDelegate)? = nil,
        delegateQueue: OperationQueue? = nil
    ) -> URLSession {
        URLSession(configuration: gated(configuration, site: site), delegate: delegate, delegateQueue: delegateQueue)
    }

    /// `configuration` with the gate's protocol first. Use it where a configuration is handed to code that
    /// makes its own session.
    public static func gated(_ configuration: URLSessionConfiguration, site: String) -> URLSessionConfiguration {
        var classes = configuration.protocolClasses ?? []
        classes.removeAll { $0 == EgressURLProtocol.self }
        classes.insert(EgressURLProtocol.self, at: 0)
        configuration.protocolClasses = classes
        return configuration
    }

    /// The gated stand-in for `URLSession.shared`.
    public static let shared: URLSession = session(site: "URLSession.shared")

    /// A WebSocket task on `session` whose URL passed the gate. When the gate refuses it, the task is made
    /// for `egress-refused.invalid` instead, so it fails at connect through the caller's own error path.
    public static func webSocketTask(in session: URLSession, with request: URLRequest, site: String) -> URLSessionWebSocketTask {
        do {
            try check(request.url, site: site)
            return session.webSocketTask(with: request)
        } catch {
            var refused = request
            refused.url = refusedURL(request.url)
            return session.webSocketTask(with: refused)
        }
    }

    public static func webSocketTask(in session: URLSession, with url: URL, site: String) -> URLSessionWebSocketTask {
        webSocketTask(in: session, with: URLRequest(url: url), site: site)
    }

    public static func webSocketTask(in session: URLSession, with url: URL, protocols: [String], site: String) -> URLSessionWebSocketTask {
        var request = URLRequest(url: url)
        if !protocols.isEmpty {
            request.setValue(protocols.joined(separator: ", "), forHTTPHeaderField: "Sec-WebSocket-Protocol")
        }
        return webSocketTask(in: session, with: request, site: site)
    }

    static let refusedHost = "egress-refused.invalid"

    static func refusedURL(_ url: URL?) -> URL? {
        guard let url, var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        parts.host = refusedHost
        parts.user = nil
        parts.password = nil
        return parts.url ?? url
    }

    // MARK: Network.framework

    #if canImport(Network)
    /// The host an endpoint names, or nil for one that names none (a service, a Unix socket).
    static func host(of endpoint: NWEndpoint) -> String? {
        switch endpoint {
        case let .hostPort(host, _):
            switch host {
            case let .name(name, _): return name
            case let .ipv4(address): return "\(address)"
            case let .ipv6(address): return "\(address)"
            @unknown default: return nil
            }
        case let .url(url): return url.host
        default: return nil
        }
    }

    /// An NWConnection to `endpoint` that passed the gate. When the gate refuses it, the connection is made
    /// to `egress-refused.invalid` instead, so it fails through the caller's own state handler.
    public static func connection(to endpoint: NWEndpoint, using parameters: NWParameters, site: String) -> NWConnection {
        if let host = host(of: endpoint) {
            do {
                try check(host, site: site)
            } catch {
                var port: NWEndpoint.Port = 443
                if case let .hostPort(_, p) = endpoint { port = p }
                return NWConnection(to: .hostPort(host: .name(refusedHost, nil), port: port), using: parameters)
            }
        }
        return NWConnection(to: endpoint, using: parameters)
    }

    public static func connection(host: NWEndpoint.Host, port: NWEndpoint.Port, using parameters: NWParameters, site: String) -> NWConnection {
        connection(to: .hostPort(host: host, port: port), using: parameters, site: site)
    }
    #endif
}

/// The URLProtocol `Egress.session` puts first: it takes a request only to refuse it (an unlisted host in
/// enforce mode), so every other request goes on to the system's loader unchanged.
public final class EgressURLProtocol: URLProtocol, @unchecked Sendable {
    static func site(of request: URLRequest) -> String { "URLSession" }

    override public class func canInit(with request: URLRequest) -> Bool {
        guard let url = request.url, let scheme = url.scheme?.lowercased(),
              ["http", "https", "ws", "wss"].contains(scheme) else { return false }
        do {
            try Egress.check(url, site: site(of: request))
            return false
        } catch {
            return true
        }
    }

    override public class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override public func startLoading() {
        let host = request.url?.host ?? ""
        let refused = Egress.Refused(host: host, site: Self.site(of: request))
        client?.urlProtocol(self, didFailWithError: URLError(.cannotFindHost, userInfo: [
            NSLocalizedDescriptionKey: refused.description,
            NSURLErrorFailingURLErrorKey: request.url as Any,
        ]))
    }

    override public func stopLoading() {}
}
