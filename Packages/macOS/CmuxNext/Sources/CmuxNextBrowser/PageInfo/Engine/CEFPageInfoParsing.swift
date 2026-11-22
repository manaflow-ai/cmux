import Foundation

/// Parsing of the DevTools results Page Info uses (pure, tested).
nonisolated enum CEFPageInfoParsing {
    /// `Network.getCertificate`: `tableNames` holds base64 DER, leaf first.
    static func certificates(_ json: String) -> [Data] {
        (object(json)?["tableNames"] as? [String] ?? []).compactMap { Data(base64Encoded: $0) }
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

    private static func object(_ json: String) -> [String: Any]? {
        guard let data = json.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}
