import Foundation

/// Parsing of the DevTools results Page Info uses (pure, tested).
nonisolated enum CEFPageInfoParsing {
    struct Cookie: Hashable {
        var name: String
        var domain: String
        var path: String
    }

    /// `Network.getCertificate`: `tableNames` holds base64 DER, leaf first.
    static func certificates(_ json: String) -> [Data] {
        (object(json)?["tableNames"] as? [String] ?? []).compactMap { Data(base64Encoded: $0) }
    }

    /// `Network.getCookies` / `Storage.getCookies`.
    static func cookies(_ json: String) -> [Cookie] {
        (object(json)?["cookies"] as? [[String: Any]] ?? []).compactMap { cookie in
            guard let name = cookie["name"] as? String, let domain = cookie["domain"] as? String else { return nil }
            return Cookie(name: name, domain: domain, path: cookie["path"] as? String ?? "/")
        }
    }

    /// Origins of every frame and resource in `Page.getResourceTree`.
    static func resourceOrigins(_ json: String) -> [String] {
        var origins: [String] = []
        var seen: Set<String> = []
        func visit(_ tree: [String: Any]) {
            let frame = tree["frame"] as? [String: Any]
            var urls = [frame?["url"] as? String].compactMap(\.self)
            urls += (tree["resources"] as? [[String: Any]] ?? []).compactMap { $0["url"] as? String }
            for url in urls {
                guard let parsed = URL(string: url), let origin = PageInfoSite.origin(of: parsed),
                      parsed.scheme == "https" || parsed.scheme == "http", seen.insert(origin).inserted else { continue }
                origins.append(origin)
            }
            (tree["childFrames"] as? [[String: Any]] ?? []).forEach(visit)
        }
        if let tree = object(json)?["frameTree"] as? [String: Any] { visit(tree) }
        return origins
    }

    /// `Target.getTargetInfo` browser context of the tab.
    static func browserContextID(_ json: String) -> String? {
        (object(json)?["targetInfo"] as? [String: Any])?["browserContextId"] as? String
    }

    /// A script whose value is each permission's state ("granted",
    /// "denied", "prompt", or null when the name is unknown).
    static func permissionQueryScript(names: [String]) -> String {
        let list = names.map { "'\($0)'" }.joined(separator: ",")
        return "Promise.all([\(list)].map(n => navigator.permissions.query(n === 'midi' ? {name: n, sysex: true} : {name: n}).then(s => s.state, () => null)))"
    }

    private static func object(_ json: String) -> [String: Any]? {
        guard let data = json.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}
