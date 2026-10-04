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
    /// says the answer may be given (the session the chooser was routed to
    /// answers it, and the chooser is still open). Nothing is written before
    /// that, nor for an answer with more than ``maximumFiles`` files, more
    /// than ``maximumBytes`` bytes, or a file that is not valid Base64
    /// (`invalid`). A write that fails removes what this call wrote.
    /// - Returns: `nil` when `authorized` refuses.
    public func stage(_ files: [[String: Any]], authorized: () -> Bool) throws -> Staged? {
        guard authorized() else { return nil }
        guard files.count <= Self.maximumFiles else {
            throw BrowserReplDriverError(code: "invalid", message: "A file chooser takes at most \(Self.maximumFiles) files")
        }
        var decoded: [(name: String, data: Data)] = []
        var total = 0
        for file in files {
            let raw = file["base64"] as? String ?? ""
            // Decoded size, bounded before the bytes are decoded.
            total += raw.utf8.count / 4 * 3
            guard total <= Self.maximumBytes + 2 * files.count else {
                throw BrowserReplDriverError(code: "invalid", message: "The files for a file chooser may hold at most \(Self.maximumBytes / (1024 * 1024)) MiB")
            }
            guard let data = Data(base64Encoded: raw) else {
                throw BrowserReplDriverError(code: "invalid", message: "A file for the file chooser is not valid Base64")
            }
            var name = ((file["name"] as? String) ?? "file").replacingOccurrences(of: "/", with: "_")
            if name.isEmpty || name == "." || name == ".." { name = "file" }
            guard !decoded.contains(where: { $0.name == name }) else {
                throw BrowserReplDriverError(code: "invalid", message: "Two files for the file chooser are named \(name)")
            }
            decoded.append((name, data))
        }
        guard decoded.reduce(0, { $0 + $1.data.count }) <= Self.maximumBytes else {
            throw BrowserReplDriverError(code: "invalid", message: "The files for a file chooser may hold at most \(Self.maximumBytes / (1024 * 1024)) MiB")
        }
        let directory = parent.appendingPathComponent("cmux-repl-upload-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        do {
            let urls = try decoded.map { file in
                let url = directory.appendingPathComponent(file.name)
                try file.data.write(to: url, options: .withoutOverwriting)
                return url
            }
            return Staged(directory: directory, urls: urls)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }
}
