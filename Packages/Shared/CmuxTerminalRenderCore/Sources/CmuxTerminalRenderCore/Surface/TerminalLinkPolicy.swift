public import Foundation

/// Which links a tap may open. Terminal output is untrusted: only web, mail
/// and remote-shell schemes open, and never a local file, script or app
/// scheme a program printed.
public struct TerminalLinkPolicy: Hashable, Sendable {
    public var allowedSchemes: Set<String>
    public var maximumLength: Int

    public init(allowedSchemes: Set<String> = ["http", "https", "mailto", "ssh"], maximumLength: Int = 4096) {
        self.allowedSchemes = Set(allowedSchemes.map { $0.lowercased() })
        self.maximumLength = maximumLength
    }

    /// The URL to open for a link Ghostty matched (OSC 8 or detected text),
    /// or nil when it must not open. A bare `www.` host opens as https.
    public func url(for link: String) -> URL? {
        let text = link.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.utf8.count <= maximumLength,
              !text.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) else { return nil }
        let candidate = text.lowercased().hasPrefix("www.") ? "https://" + text : text
        guard let url = URL(string: candidate), let scheme = url.scheme?.lowercased(),
              allowedSchemes.contains(scheme) else { return nil }
        if scheme == "http" || scheme == "https" || scheme == "ssh" {
            guard let host = url.host, !host.isEmpty else { return nil }
        }
        return url
    }
}
