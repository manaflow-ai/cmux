import Foundation

@MainActor
final class MobileDiffPatchStore {
    private var payloads: [Int: MobileDiffPatchPayload] = [:]

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
        guard path.hasPrefix("webviews-app/") || path.hasPrefix("diff-viewer/"),
              path.hasSuffix(".mjs") || path.hasSuffix(".js"),
              let resourceRoot = Bundle.main.resourceURL?.standardizedFileURL else { return nil }
        let fileURL = resourceRoot.appendingPathComponent(String(path)).standardizedFileURL
        guard fileURL.path.hasPrefix(resourceRoot.path + "/"),
              let data = try? Data(contentsOf: fileURL) else { return nil }
        return MobileDiffPatchContent(data: data, mimeType: "text/javascript")
    }

    private func generation(in path: Substring, prefix: String, suffix: String) -> Int? {
        guard path.hasPrefix(prefix), path.hasSuffix(suffix) else { return nil }
        return Int(path.dropFirst(prefix.count).dropLast(suffix.count))
    }
}
