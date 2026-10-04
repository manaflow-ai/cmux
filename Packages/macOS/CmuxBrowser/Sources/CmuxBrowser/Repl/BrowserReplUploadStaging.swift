public import Foundation

/// Writes the files of a REPL file chooser answer (`filechooser.respond`
/// `files: [{ name, base64 }]`) to disk for WebKit's open panel, which
/// takes file URLs.
public struct BrowserReplUploadStaging: Sendable {
    /// Files one answer may hold.
    public static let maximumFiles = 256
    /// Bytes, decoded, all files of one answer may hold together.
    public static let maximumBytes = 256 * 1024 * 1024

    /// Where each answer's directory goes.
    public let parent: URL

    public init(parent: URL) {
        self.parent = parent
    }

    /// The staged answer: a new directory that holds the files, and their URLs.
    public struct Staged: Sendable, Equatable {
        public let directory: URL
        public let urls: [URL]
    }

    /// Stages `files` in a new directory under ``parent``, once `authorized`
    /// says the answer may be given. Seam: today's order.
    public func stage(_ files: [[String: Any]], authorized: () -> Bool) throws -> Staged? {
        let directory = parent.appendingPathComponent("cmux-repl-upload-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let urls = try files.map { file in
            let name = ((file["name"] as? String) ?? "file").replacingOccurrences(of: "/", with: "_")
            let url = directory.appendingPathComponent(name.isEmpty ? "file" : name)
            try (Data(base64Encoded: file["base64"] as? String ?? "") ?? Data()).write(to: url)
            return url
        }
        guard authorized() else { return nil }
        return Staged(directory: directory, urls: urls)
    }
}
