import Foundation

enum FilePreviewTextSaver {
    @concurrent
    static func save(content: String, to url: URL, encoding: String.Encoding) async -> FilePreviewTextSaveResult {
        guard let data = content.data(using: encoding) else {
            return .failed(fileExists: FileManager.default.fileExists(atPath: url.path))
        }

        do {
            try data.write(to: url, options: [])
            return .saved
        } catch {
            return .failed(fileExists: FileManager.default.fileExists(atPath: url.path))
        }
    }
}
