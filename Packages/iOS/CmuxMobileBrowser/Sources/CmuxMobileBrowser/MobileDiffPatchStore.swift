import Foundation

@MainActor
final class MobileDiffPatchStore {
    private let assetLoader: @Sendable (URL?) -> [String: MobileDiffPatchContent]
    private let resourceRoot: URL?
    private var assets: [String: MobileDiffPatchContent]?
    private var payloads: [Int: MobileDiffPatchPayload] = [:]

    init(
        resourceRoot: URL? = Bundle.main.resourceURL,
        assetLoader: @escaping @Sendable (URL?) -> [String: MobileDiffPatchContent] = mobileDiffLoadBundledAssets
    ) {
        self.resourceRoot = resourceRoot
        self.assetLoader = assetLoader
    }

    func configure(generation: Int, html: Data, patch: Data) async {
        if assets == nil {
            let assetLoader = assetLoader
            let resourceRoot = resourceRoot
            assets = await Task.detached(priority: .userInitiated) {
                assetLoader(resourceRoot)
            }.value
        }
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
        return assets?[String(path)]
    }

    private func generation(in path: Substring, prefix: String, suffix: String) -> Int? {
        guard path.hasPrefix(prefix), path.hasSuffix(suffix) else { return nil }
        return Int(path.dropFirst(prefix.count).dropLast(suffix.count))
    }

}

// lint:allow File-scope pure helper required by the cmux package-design policy.
private func mobileDiffLoadBundledAssets(
    resourceRoot: URL?
) -> [String: MobileDiffPatchContent] {
    guard let resourceRoot = resourceRoot?.standardizedFileURL else { return [:] }
    var assets: [String: MobileDiffPatchContent] = [:]
    for directoryName in ["webviews-app", "diff-viewer"] {
        let directory = resourceRoot.appendingPathComponent(directoryName, isDirectory: true)
        guard let enumerator = FileManager().enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { continue }
        for case let fileURL as URL in enumerator {
            guard fileURL.pathExtension == "mjs" || fileURL.pathExtension == "js",
                  (try? fileURL.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
                  let data = try? Data(contentsOf: fileURL) else { continue }
            let relativePath = String(fileURL.standardizedFileURL.path.dropFirst(resourceRoot.path.count + 1))
            assets[relativePath] = MobileDiffPatchContent(data: data, mimeType: "text/javascript")
        }
    }
    return assets
}
