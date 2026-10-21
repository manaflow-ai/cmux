import Foundation

/// What an extension's `manifest.json` asks for, as far as the Extensions bubble shows it: the
/// sites it reads and changes, whether it runs on a click (`activeTab`), and whether it has a
/// side panel. The fork's `cmux_ext_list` reports none of this, so the bubble reads the manifest
/// in the extension's folder (Chromium installs each version in its own folder, so a path names
/// one manifest).
nonisolated struct ExtensionManifestFacts: Equatable, Sendable {
    /// Match patterns of the sites it can read and change: `host_permissions` (MV3), host
    /// entries of `permissions` (MV2), and its content scripts' `matches`.
    var hostPatterns: [String] = []
    /// `activeTab`: it gets the page only when the person clicks it.
    var activeTab = false
    /// `side_panel.default_path`: it opens a side panel.
    var sidePanel = false
    /// Its action opens a popup (`action` / `browser_action` `default_popup`).
    var actionPopup = false

    init(hostPatterns: [String] = [], activeTab: Bool = false, sidePanel: Bool = false, actionPopup: Bool = false) {
        self.hostPatterns = hostPatterns
        self.activeTab = activeTab
        self.sidePanel = sidePanel
        self.actionPopup = actionPopup
    }

    /// Reads a manifest's JSON (Chromium accepts comments and trailing commas); nil when it is no
    /// JSON object.
    init?(json data: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: data, options: [.json5Allowed]) as? [String: Any] else {
            return nil
        }
        let permissions = (object["permissions"] as? [Any])?.compactMap { $0 as? String } ?? []
        let hosts = (object["host_permissions"] as? [Any])?.compactMap { $0 as? String } ?? []
        let scripts = (object["content_scripts"] as? [[String: Any]] ?? []).flatMap { ($0["matches"] as? [String]) ?? [] }
        var patterns: [String] = []
        for pattern in hosts + permissions.filter(Self.isHostPattern) + scripts where !patterns.contains(pattern) {
            patterns.append(pattern)
        }
        hostPatterns = patterns
        activeTab = permissions.contains("activeTab")
        sidePanel = ((object["side_panel"] as? [String: Any])?["default_path"] as? String).map { !$0.isEmpty } ?? false
        let action = (object["action"] ?? object["browser_action"]) as? [String: Any]
        actionPopup = (action?["default_popup"] as? String).map { !$0.isEmpty } ?? false
    }

    /// Reads `manifest.json` in extension folder `path`; nil when it is missing or unreadable.
    init?(folder path: String) {
        guard !path.isEmpty,
              let data = FileManager.default.contents(atPath: (path as NSString).appendingPathComponent("manifest.json")) else {
            return nil
        }
        self.init(json: data)
    }

    /// A permission that names sites rather than an API (`<all_urls>`, `https://*/*`).
    static func isHostPattern(_ permission: String) -> Bool {
        permission == "<all_urls>" || permission.contains("://")
    }
}

/// How much of the current site an extension can see and change, the line under its name in
/// the Extensions bubble (Edge's "Allowed on all sites" / "Allowed on this site" / "Allowed only
/// when clicked"), from the sites its manifest asks for.
nonisolated enum ExtensionSiteAccess: Equatable, Sendable {
    case allSites
    case thisSite
    case whenClicked
    case none
    /// Its manifest was not read (yet, or the fork lists no folder): no line and no section,
    /// rather than claiming it asks for nothing.
    case unknown

    /// Chrome's sections of the bubble, in their order.
    enum Group: Int, CaseIterable, Sendable {
        /// "Can see and change this site".
        case canSeeAndChange
        /// "Allowed only when clicked".
        case whenClicked
        /// "No access needed".
        case noAccess
    }

    /// The section the extension is listed in; nil for ``unknown``, listed after the sections.
    var group: Group? {
        switch self {
        case .allSites, .thisSite: .canSeeAndChange
        case .whenClicked: .whenClicked
        case .none: .noAccess
        case .unknown: nil
        }
    }

    /// The access of an extension asking for `facts` on page `url` (nil or a page that is no web
    /// site: only all-sites patterns count).
    init(_ facts: ExtensionManifestFacts?, url: URL?) {
        guard let facts else {
            self = .unknown
            return
        }
        if facts.hostPatterns.contains(where: Self.isAllSites) {
            self = .allSites
        } else if let url, facts.hostPatterns.contains(where: { Self.pattern($0, matches: url) }) {
            self = .thisSite
        } else if facts.activeTab {
            self = .whenClicked
        } else {
            self = .none
        }
    }

    /// A pattern for every web site: `<all_urls>`, or any scheme of `*` with any path.
    static func isAllSites(_ pattern: String) -> Bool {
        if pattern == "<all_urls>" { return true }
        guard case let (scheme, host)? = parts(pattern) else { return false }
        return host == "*" && ["*", "http", "https"].contains(scheme)
    }

    /// Whether match pattern `pattern` covers `url`'s site (Chrome's `URLPattern`, by scheme and
    /// host; the path does not change the site's access).
    static func pattern(_ pattern: String, matches url: URL) -> Bool {
        guard let urlScheme = url.scheme?.lowercased(), ["http", "https"].contains(urlScheme),
              let urlHost = url.host?.lowercased() else { return false }
        if pattern == "<all_urls>" { return true }
        guard case let (scheme, host)? = parts(pattern) else { return false }
        guard scheme == "*" || scheme == urlScheme else { return false }
        if host == "*" { return true }
        if host.hasPrefix("*.") {
            let domain = String(host.dropFirst(2))
            return urlHost == domain || urlHost.hasSuffix("." + domain)
        }
        return urlHost == host
    }

    /// The scheme and host of match pattern `scheme://host/path`, lowercased, without a port.
    private static func parts(_ pattern: String) -> (String, String)? {
        guard let separator = pattern.range(of: "://") else { return nil }
        let scheme = pattern[..<separator.lowerBound].lowercased()
        let rest = pattern[separator.upperBound...]
        let slash = rest.firstIndex(of: "/") ?? rest.endIndex
        var host = rest[..<slash].lowercased()
        if let colon = host.lastIndex(of: ":"), !host.hasSuffix("]") { host = String(host[..<colon]) }
        return (scheme, host)
    }
}
