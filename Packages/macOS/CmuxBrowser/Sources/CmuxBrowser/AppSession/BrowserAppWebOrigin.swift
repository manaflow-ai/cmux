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
}

private func effectivePort(_ url: URL) -> Int? {
    if let port = url.port { return port }
    switch url.scheme?.lowercased() {
    case "http": return 80
    case "https": return 443
    default: return nil
    }
}
