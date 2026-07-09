public import Foundation
public import UniformTypeIdentifiers

/// A request to open a file by running it in a terminal: the file URL, the
/// working directory to start in, and the initial shell input that runs the
/// file.
///
/// Lifted byte-for-byte from AppDelegate's `TerminalDefaultFileOpenRequest`.
/// The failable initializer returns `nil` unless the URL is a non-directory
/// file that should run in a terminal (a `.command`/`.tool`/shell-script
/// content type, a unix-executable content type, or an executable file). The
/// deep-link/services entry points build these from the externally-opened URLs
/// and route the survivors into a new workspace whose terminal runs the file.
public struct TerminalDefaultFileOpenRequest: Equatable, Sendable {
    /// The standardized file URL to run.
    public let fileURL: URL
    /// The directory the terminal starts in (the file's parent directory).
    public let workingDirectory: String
    /// The initial terminal input: the shell-quoted file path followed by a
    /// newline.
    public let initialInput: String

    /// Creates a request, or returns `nil` when the URL should not run in a
    /// terminal.
    /// - Parameters:
    ///   - fileURL: The candidate file URL; must be a `file:` URL.
    ///   - contentType: The pre-resolved content type, or `nil` to read it
    ///     from the file's resource values.
    ///   - isExecutable: The pre-resolved executable flag, or `nil` to read it
    ///     from the file's resource values and `FileManager`.
    public init?(fileURL: URL, contentType: UTType? = nil, isExecutable: Bool? = nil) {
        guard fileURL.isFileURL else { return nil }
        let standardizedURL = fileURL.standardizedFileURL
        let directoryCheckURL = standardizedURL.resolvingSymlinksInPath()
        let resourceValues = try? directoryCheckURL.resourceValues(forKeys: [.isDirectoryKey])
        guard resourceValues?.isDirectory != true else { return nil }
        let resolvedContentType = contentType ?? Self.contentType(for: standardizedURL)
        let resolvedIsExecutable = isExecutable ?? Self.isExecutableFile(directoryCheckURL)
        guard Self.shouldRunInTerminal(
            fileURL: standardizedURL,
            contentType: resolvedContentType,
            isExecutable: resolvedIsExecutable
        ) else {
            return nil
        }

        self.fileURL = standardizedURL
        self.workingDirectory = standardizedURL.deletingLastPathComponent().path(percentEncoded: false)
        self.initialInput = "\(Self.shellSingleQuoted(standardizedURL.path(percentEncoded: false)))\n"
    }

    /// Builds the de-duplicated, terminal-eligible requests from a list of
    /// URLs, preserving input order.
    /// - Parameter urls: The candidate URLs.
    /// - Returns: One request per unique terminal-eligible file path.
    public static func requests(from urls: [URL]) -> [TerminalDefaultFileOpenRequest] {
        var seen: Set<String> = []
        var requests: [TerminalDefaultFileOpenRequest] = []
        for url in urls {
            guard let request = TerminalDefaultFileOpenRequest(fileURL: url) else { continue }
            let path = request.fileURL.path(percentEncoded: false)
            guard seen.insert(path).inserted else { continue }
            requests.append(request)
        }
        return requests
    }

    private static func contentType(for fileURL: URL) -> UTType? {
        try? fileURL.resourceValues(forKeys: [.contentTypeKey]).contentType
    }

    private static func isExecutableFile(_ fileURL: URL) -> Bool {
        if (try? fileURL.resourceValues(forKeys: [.isExecutableKey]).isExecutable) == true {
            return true
        }
        return FileManager.default.isExecutableFile(atPath: fileURL.path(percentEncoded: false))
    }

    private static func shouldRunInTerminal(fileURL: URL, contentType: UTType?, isExecutable: Bool) -> Bool {
        if isTerminalShellScript(fileURL: fileURL, contentType: contentType) {
            return true
        }
        return contentType?.conforms(to: .unixExecutable) == true || isExecutable
    }

    private static func isTerminalShellScript(fileURL: URL, contentType: UTType?) -> Bool {
        if contentType?.identifier == "com.apple.terminal.shell-script" {
            return true
        }
        switch fileURL.pathExtension.lowercased() {
        case "command", "tool":
            return true
        default:
            return false
        }
    }

    private static func shellSingleQuoted(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }
}
