public import Foundation

/// Which enabled extensions of a profile can reach a page, from their
/// manifests. Interim rule until the fork blocks extensions per tab (P6):
/// an agent may not drive a page that one of them can reach, because a
/// password manager's content script or inline menu can fill a password
/// that the agent's script then reads (plans/cmux-next/passwords.md,
/// section 3.4).
///
/// Counted: `host_permissions`, `optional_host_permissions` (they may be
/// granted at runtime), `content_scripts[].matches`, and host patterns in
/// MV2 `permissions`/`optional_permissions`. Not counted: `activeTab`
/// (granted only when the person invokes the extension). Fail closed: an
/// unreadable manifest or a pattern this rule cannot parse counts as access.
/// Paths of patterns are ignored (Chrome ignores them for host permissions;
/// for content scripts this over-counts, which is the safe side).
public nonisolated struct AgentExtensionAccess {
    let manifest: (String) -> [String: Any]?

    /// `manifest` reads an extension folder's parsed manifest.json.
    public init(manifest: @escaping (String) -> [String: Any]?) { self.manifest = manifest }

    /// Reads `<extension path>/manifest.json` from disk.
    public static var fromDisk: AgentExtensionAccess {
        AgentExtensionAccess { path in
            guard let data = FileManager.default.contents(atPath: (path as NSString).appendingPathComponent("manifest.json")) else { return nil }
            return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        }
    }

    /// The enabled extensions that can reach `url`. A page that is not a web
    /// or file page (about:blank, none yet) has nothing to read.
    public func blockers(_ extensions: [BrowserExtensionInfo], url: URL?) -> [BrowserExtensionInfo] {
        guard let url, let scheme = url.scheme?.lowercased(), Self.pageSchemes.contains(scheme) else { return [] }
        return extensions.filter { info in
            guard info.isEnabled else { return false }
            guard let manifest = manifest(info.path) else { return true }
            return Self.patterns(manifest).contains { matches($0, url) }
        }
    }

    static let pageSchemes: Set<String> = ["http", "https", "file", "ws", "wss", "ftp"]

    static func patterns(_ manifest: [String: Any]) -> [String] {
        var out: [String] = []
        for key in ["host_permissions", "optional_host_permissions"] { out += manifest[key] as? [String] ?? [] }
        for script in manifest["content_scripts"] as? [[String: Any]] ?? [] { out += script["matches"] as? [String] ?? [] }
        for key in ["permissions", "optional_permissions"] {
            out += (manifest[key] as? [Any] ?? []).compactMap { $0 as? String }.filter { $0 == "<all_urls>" || $0.contains("://") }
        }
        return out
    }

    /// Chrome match pattern against a page URL (scheme and host; any path).
    public func matches(_ pattern: String, _ url: URL) -> Bool {
        let scheme = url.scheme?.lowercased() ?? ""
        if pattern == "<all_urls>" { return Self.pageSchemes.contains(scheme) }
        guard let separator = pattern.range(of: "://") else { return true }
        let patternScheme = pattern[..<separator.lowerBound].lowercased()
        let rest = pattern[separator.upperBound...]
        guard let slash = rest.firstIndex(of: "/") else { return true }
        var host = rest[..<slash].lowercased()
        switch patternScheme {
        case "*": guard ["http", "https", "ws", "wss"].contains(scheme) else { return false }
        case "http", "https", "ws", "wss", "ftp", "file": guard patternScheme == scheme else { return false }
        default: return false
        }
        if scheme == "file" { return true }
        if let colon = host.lastIndex(of: ":"), !host.hasSuffix("]") {
            let port = host[host.index(after: colon)...]
            host = String(host[..<colon])
            if port != "*", let wanted = Int(port), wanted != (url.port ?? Self.defaultPort(scheme)) { return false }
        }
        let pageHost = (url.host() ?? "").lowercased()
        if host == "*" { return true }
        if host.hasPrefix("*.") {
            let base = String(host.dropFirst(2))
            return pageHost == base || pageHost.hasSuffix("." + base)
        }
        if host.contains("*") { return true }
        return pageHost == host
    }

    static func defaultPort(_ scheme: String) -> Int {
        switch scheme {
        case "http", "ws": 80
        case "https", "wss": 443
        case "ftp": 21
        default: -1
        }
    }
}
