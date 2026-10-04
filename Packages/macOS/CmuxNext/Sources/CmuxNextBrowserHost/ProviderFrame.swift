public import CmuxNextBrowser
public import CmuxNextBrowserAutomation
import Foundation

/// One provider frame (app <-> host), tagged by `t` on the wire. Mirrors
/// `Frame` in cmux-tui/crates/cmux-browser-host/src/provider.rs field for field.
public nonisolated enum ProviderFrame: Hashable, Sendable {
    case hello(version: UInt32, providerID: String, installID: String, secret: ProviderSecret,
               engines: [String], tabs: [ProviderTabAnnounce])
    case helloAck(agentBundle: String, agentBundleSHA: String)
    /// A driver protocol call on a WebKit tab (host -> app).
    case call(id: UInt64, method: String, params: DriverJSON)
    /// The answer to a `call`: `error` is `{code, message, errorName?}`.
    case result(id: UInt64, result: DriverJSON?, error: DriverJSON?)
    /// A driver event or a provider event (`tab.announced`, `tab.navigated`, `tab.gone`).
    case event(name: String, payload: DriverJSON)
    case cdpAttach(targetID: String)
    case cdpDetach(targetID: String)
    /// One raw CDP message for a CEF tab.
    case cdp(targetID: String, message: String)
    case lease(targetID: String, lease: ProviderLease?)
    case userInput(targetID: String)
    /// Whether agents may drive a CEF tab (app -> host; interim extension rule).
    case tabAccess(targetID: String, extensionHostAccess: Bool, userOverride: Bool, extensions: [String])
    /// A frame tag this app does not know (a newer host); ignored.
    case unknown(tag: String)

    /// The wire tag (`t`).
    public var tag: String {
        switch self {
        case .hello: "hello"
        case .helloAck: "hello.ack"
        case .call: "call"
        case .result: "result"
        case .event: "event"
        case .cdpAttach: "cdp.attach"
        case .cdpDetach: "cdp.detach"
        case .cdp: "cdp"
        case .lease: "lease"
        case .userInput: "user.input"
        case .tabAccess: "tab.access"
        case .unknown(let tag): tag
        }
    }
}

/// Descriptions name the frame and its ids only: the secret, call params,
/// results and raw CDP messages can carry typed text and page data.
extension ProviderFrame: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public nonisolated var description: String {
        switch self {
        case .hello(let version, let providerID, let installID, _, let engines, let tabs):
            "hello(version: \(version), provider: \(providerID), install: \(installID), engines: \(engines), tabs: \(tabs.count))"
        case .helloAck(let bundle, let sha): "hello.ack(bundle: \(bundle.utf8.count) bytes, sha: \(sha))"
        case .call(let id, let method, _): "call(id: \(id), method: \(method))"
        case .result(let id, _, let error): "result(id: \(id), error: \(error != nil))"
        case .event(let name, _): "event(\(name))"
        case .cdpAttach(let target): "cdp.attach(\(target))"
        case .cdpDetach(let target): "cdp.detach(\(target))"
        case .cdp(let target, let message): "cdp(\(target), \(message.utf8.count) bytes)"
        case .lease(let target, let lease): "lease(\(target), \(lease.map(\.session) ?? "none"))"
        case .userInput(let target): "user.input(\(target))"
        case .tabAccess(let target, let access, let override, _): "tab.access(\(target), \(access), override: \(override))"
        case .unknown(let tag): "unknown(\(tag))"
        }
    }

    public nonisolated var debugDescription: String { description }
    public nonisolated var customMirror: Mirror { Mirror(self, children: ["frame": description]) }
}
