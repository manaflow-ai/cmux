public import Foundation

extension URL {
    /// Parses the `Web UI available at <url>` line emitted by VS Code's
    /// `serve-web`/`code-server` process and returns the advertised URL.
    ///
    /// Scans `output` newest-line-first, trims the text after the
    /// `Web UI available at ` prefix, and returns the first well-formed URL.
    /// Byte-faithful lift of the former app-target
    /// `VSCodeServeWebURLBuilder.extractWebUIURL(from:)` namespace method.
    public static func vscodeServeWebUIURL(parsedFrom output: String) -> URL? {
        let prefix = "Web UI available at "
        for line in output.split(whereSeparator: \.isNewline).reversed() {
            guard let range = line.range(of: prefix) else { continue }
            let rawURL = line[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !rawURL.isEmpty, let url = URL(string: rawURL) else { continue }
            return url
        }
        return nil
    }

    /// Returns a copy of this serve-web base URL with its `folder` query item
    /// set to `directoryPath`, replacing any existing `folder` item while
    /// preserving every other query item (e.g. the connection token).
    ///
    /// `self` is the base Web UI URL. Byte-faithful lift of the former
    /// app-target `VSCodeServeWebURLBuilder.openFolderURL(baseWebUIURL:directoryPath:)`.
    public func vscodeServeWebFolderURL(directoryPath: String) -> URL? {
        var components = URLComponents(url: self, resolvingAgainstBaseURL: false)
        var queryItems = components?.queryItems ?? []
        queryItems.removeAll { $0.name == "folder" }
        queryItems.append(URLQueryItem(name: "folder", value: directoryPath))
        components?.queryItems = queryItems
        return components?.url
    }
}
