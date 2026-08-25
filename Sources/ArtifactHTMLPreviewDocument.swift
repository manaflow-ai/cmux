import Darwin
import Foundation

/// A bounded, sandbox-wrapped HTML document safe to load as an artifact preview.
struct ArtifactHTMLPreviewDocument: Sendable {
    private static let maximumSourceBytes = 8 * 1024 * 1024

    let url: URL

    @concurrent
    static func load(
        sourceURL: URL,
        allowedRoot: URL
    ) async throws -> ArtifactHTMLPreviewDocument {
        try ArtifactHTMLPreviewDocument(sourceURL: sourceURL, allowedRoot: allowedRoot)
    }

    private init(sourceURL: URL, allowedRoot: URL) throws {
        let source = String(
            decoding: try Self.readSource(sourceURL, allowedRoot: allowedRoot),
            as: UTF8.self
        )
        let wrapper = Self.wrapper(source: source)
        let encoded = Data(wrapper.utf8).base64EncodedString()
        guard let url = URL(string: "data:text/html;base64,\(encoded)") else {
            throw CocoaError(.fileReadCorruptFile)
        }
        self.url = url
    }

    private static func readSource(_ sourceURL: URL, allowedRoot: URL) throws -> Data {
        try Task.checkCancellation()
        let descriptor = Darwin.open(
            sourceURL.path,
            O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK
        )
        guard descriptor >= 0 else {
            throw CocoaError(.fileReadUnknown, userInfo: [NSFilePathErrorKey: sourceURL.path])
        }
        defer { Darwin.close(descriptor) }

        var status = stat()
        guard fstat(descriptor, &status) == 0,
              (status.st_mode & S_IFMT) == S_IFREG,
              status.st_size >= 0 else {
            throw CocoaError(.fileReadUnknown, userInfo: [NSFilePathErrorKey: sourceURL.path])
        }
        guard let openedPath = openedPath(for: descriptor),
              isPath(openedPath, inside: allowedRoot) else {
            throw CocoaError(.fileReadUnknown, userInfo: [NSFilePathErrorKey: sourceURL.path])
        }
        guard status.st_size <= Self.maximumSourceBytes else {
            throw CocoaError(.fileReadTooLarge)
        }

        var data = Data()
        data.reserveCapacity(min(Int(status.st_size), Self.maximumSourceBytes))
        var buffer = [UInt8](
            repeating: 0,
            count: min(64 * 1024, Self.maximumSourceBytes + 1)
        )
        while data.count <= Self.maximumSourceBytes {
            try Task.checkCancellation()
            let requested = min(buffer.count, Self.maximumSourceBytes + 1 - data.count)
            guard requested > 0 else { break }
            let count = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(descriptor, bytes.baseAddress, requested)
            }
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                throw CocoaError(.fileReadUnknown, userInfo: [NSFilePathErrorKey: sourceURL.path])
            }
            data.append(contentsOf: buffer.prefix(count))
        }
        guard data.count <= Self.maximumSourceBytes else {
            throw CocoaError(.fileReadTooLarge)
        }
        return data
    }

    private static func openedPath(for descriptor: Int32) -> URL? {
        var buffer = [UInt8](repeating: 0, count: Int(PATH_MAX))
        let result = buffer.withUnsafeMutableBytes { bytes in
            fcntl(descriptor, F_GETPATH, bytes.baseAddress)
        }
        guard result == 0 else { return nil }
        let path = String(decoding: buffer.prefix { $0 != 0 }, as: UTF8.self)
        return URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL
    }

    private static func isPath(_ path: URL, inside root: URL) -> Bool {
        let rootPath = root.resolvingSymlinksInPath().standardizedFileURL.path
        let path = path.path
        return path == rootPath
            || path.hasPrefix(rootPath.hasSuffix("/") ? rootPath : rootPath + "/")
    }

    private static func wrapper(source: String) -> String {
        let sourceDocument = source
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
        return """
        <!doctype html>
        <html>
        <head>
        <meta charset="utf-8">
        <meta name="referrer" content="no-referrer">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'none'; connect-src 'none'; object-src 'none'; form-action 'none'; base-uri 'none'; navigate-to 'none'; frame-src 'self'; child-src 'self'; style-src 'unsafe-inline'; img-src data: blob:; media-src data: blob:; font-src data:">
        <style>html,body,iframe{box-sizing:border-box;width:100%;height:100%;margin:0;border:0;background:white}iframe{display:block}</style>
        </head>
        <body><iframe sandbox="" referrerpolicy="no-referrer" srcdoc="\(sourceDocument)"></iframe></body>
        </html>
        """
    }
}
