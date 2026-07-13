import Foundation

actor MobileDiffPatchStore {
    private let dataLoader: @Sendable (URL) -> Data?
    private let resourceRoot: URL?
    private var assets: [String: MobileDiffPatchContent] = [:]
    private var payloads: [Int: MobileDiffPatchPayload] = [:]

    init(
        resourceRoot: URL? = Bundle.main.resourceURL,
        dataLoader: @escaping @Sendable (URL) -> Data? = mobileDiffLoadAssetData
    ) {
        self.resourceRoot = resourceRoot
        self.dataLoader = dataLoader
    }

    func configure(generation: Int, html: Data, patch: Data) {
        payloads[generation] = MobileDiffPatchPayload(html: html, patch: patch)
        for expiredGeneration in payloads.keys.sorted().dropLast(2) {
            payloads[expiredGeneration] = nil
        }
    }

    func content(for requestPath: String) -> MobileDiffPatchContent? {
        let path = requestPath.drop(while: { $0 == "/" })
        if let generation = generation(in: path, prefix: "index-", suffix: ".html"),
           let payload = payloads[generation] {
            return MobileDiffPatchContent(data: payload.html, mimeType: "text/html")
        }
        if let generation = generation(in: path, prefix: "patch/current-", suffix: ".diff"),
           let payload = payloads[generation] {
            return MobileDiffPatchContent(data: payload.patch, mimeType: "text/x-diff")
        }
        let assetPath = String(path)
        if let cached = assets[assetPath] { return cached }
        guard (path.hasPrefix("webviews-app/") || path.hasPrefix("diff-viewer/")),
              path.hasSuffix(".mjs") || path.hasSuffix(".js"),
              let resourceRoot = resourceRoot?.standardizedFileURL else { return nil }
        let fileURL = resourceRoot.appendingPathComponent(assetPath).standardizedFileURL
        guard fileURL.path.hasPrefix(resourceRoot.path + "/"),
              let data = dataLoader(fileURL) else { return nil }
        let content = MobileDiffPatchContent(data: data, mimeType: "text/javascript")
        assets[assetPath] = content
        return content
    }

    private func generation(in path: Substring, prefix: String, suffix: String) -> Int? {
        guard path.hasPrefix(prefix), path.hasSuffix(suffix) else { return nil }
        return Int(path.dropFirst(prefix.count).dropLast(suffix.count))
    }

}

// lint:allow File-scope pure helper required by the cmux package-design policy.
private func mobileDiffLoadAssetData(_ url: URL) -> Data? {
    try? Data(contentsOf: url, options: .mappedIfSafe)
}
