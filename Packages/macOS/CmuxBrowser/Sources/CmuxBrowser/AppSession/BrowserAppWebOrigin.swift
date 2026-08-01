import Foundation

struct BrowserAppWebOrigin {
    private let url: URL

    init(_ url: URL) {
        self.url = url
    }

    func contains(_ candidate: URL) -> Bool {
        guard candidate.scheme?.lowercased() == url.scheme?.lowercased(),
              candidate.host?.lowercased() == url.host?.lowercased() else {
            return false
        }
        return effectivePort(candidate) == effectivePort(url)
    }

    func containsAppSurface(_ candidate: URL) -> Bool {
        guard contains(candidate) else { return false }
        let normalizedPath = candidate.path.count > 1
            && candidate.path.hasSuffix("/")
            ? String(candidate.path.dropLast())
            : candidate.path
        return normalizedPath == "/app-pricing"
            || normalizedPath == "/app-pro-welcome"
    }
}

private func effectivePort(_ url: URL) -> Int? {
    if let port = url.port { return port }
    switch url.scheme?.lowercased() {
    case "http": return 80
    case "https": return 443
    default: return nil
    }
}
