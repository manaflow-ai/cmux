import Foundation

struct BrowserAppWebOrigin {
    private let url: URL

    init(_ url: URL) {
        self.url = url
    }

    func contains(_ candidate: URL) -> Bool {
        guard isSecureOrLoopbackOrigin(url),
              isSecureOrLoopbackOrigin(candidate),
              let scheme = url.scheme?.lowercased(),
              let host = url.host?.lowercased(),
              candidate.scheme?.lowercased() == scheme,
              candidate.host?.lowercased() == host else {
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

private func isSecureOrLoopbackOrigin(_ url: URL) -> Bool {
    guard url.user == nil,
          url.password == nil,
          let host = url.host?.lowercased(),
          !host.isEmpty else {
        return false
    }
    if url.scheme?.lowercased() == "https" {
        return true
    }
    guard url.scheme?.lowercased() == "http" else { return false }
    return host == "localhost"
        || host == "127.0.0.1"
        || host == "::1"
}

private func effectivePort(_ url: URL) -> Int? {
    if let port = url.port { return port }
    switch url.scheme?.lowercased() {
    case "http": return 80
    case "https": return 443
    default: return nil
    }
}
