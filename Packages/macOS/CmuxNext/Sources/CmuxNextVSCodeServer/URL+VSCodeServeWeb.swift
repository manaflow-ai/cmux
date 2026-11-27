public import Foundation

extension URL {
    /// The Web UI URL in `serve-web` output (its last `Web UI available at <url>` line), or nil.
    /// - Parameter output: Server output, one or more lines.
    public init?(vscodeServeWebOutput output: String) {
        let prefix = "Web UI available at "
        for line in output.split(whereSeparator: \.isNewline).reversed() {
            guard let range = line.range(of: prefix) else { continue }
            let raw = line[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
            if !raw.isEmpty, let url = URL(string: raw) {
                self = url
                return
            }
        }
        return nil
    }

    /// This `serve-web` URL opening `path`: its `folder` query set to the path, other queries kept.
    /// - Parameter path: The absolute folder path.
    /// - Returns: The URL, or nil when this URL has no components.
    public func vscodeServeWebURL(openingFolder path: String) -> URL? {
        guard var components = URLComponents(url: self, resolvingAgainstBaseURL: false) else { return nil }
        var items = components.queryItems ?? []
        items.removeAll { $0.name == "folder" }
        items.append(URLQueryItem(name: "folder", value: path))
        components.queryItems = items
        return components.url
    }
}
