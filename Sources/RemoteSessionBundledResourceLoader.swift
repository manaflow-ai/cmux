import Foundation

struct RemoteSessionBundledResourceLoader {
    let resourceURL: URL?
    let fileManager: FileManager

    init(
        resourceURL: URL? = Bundle.main.resourceURL,
        fileManager: FileManager = .default
    ) {
        self.resourceURL = resourceURL
        self.fileManager = fileManager
    }

    func codexWrapperScript() -> String? {
        guard let resourceURL else { return nil }
        let url = resourceURL
            .appendingPathComponent("bin", isDirectory: true)
            .appendingPathComponent("cmux-codex-wrapper", isDirectory: false)
        guard fileManager.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let contents = String(data: data, encoding: .utf8) else {
            return nil
        }
        return contents
    }
}
