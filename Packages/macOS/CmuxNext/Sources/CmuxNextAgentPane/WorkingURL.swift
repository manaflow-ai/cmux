package import Foundation

/// The dev server a terminal shows (#16620): the newest localhost URL on
/// screen, for a browser tab opened from it. Same rules as the agent pane's
/// `paneContext.ts`: `0.0.0.0` becomes `localhost`, trailing punctuation is
/// not part of the URL.
package struct WorkingURL {
    package init() {}
    private static let localHosts: Set<String> = ["localhost", "127.0.0.1", "0.0.0.0", "::1", "[::1]"]

    package static func devServer(in text: String?) -> URL? {
        guard let text else { return nil }
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        let range = NSRange(text.startIndex..., in: text)
        let links = detector?.matches(in: text, range: range).compactMap(\.url) ?? []
        for url in links.reversed() {
            guard ["http", "https"].contains(url.scheme?.lowercased() ?? ""), let host = url.host()?.lowercased(),
                  localHosts.contains(host) || host.hasSuffix(".localhost"),
                  var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { continue }
            if host == "0.0.0.0" { parts.host = "localhost" }
            while let last = parts.path.last, ".,;:!?".contains(last) { parts.path.removeLast() }
            return parts.url
        }
        return nil
    }

    /// An agent's cwd comes from its page: use it only as an absolute path
    /// to a directory on this Mac (a remote agent's folder is not one).
    package static func isDirectory(_ path: String, fileManager: FileManager = .default) -> Bool {
        var directory: ObjCBool = false
        return path.hasPrefix("/") && fileManager.fileExists(atPath: path, isDirectory: &directory) && directory.boolValue
    }
}

