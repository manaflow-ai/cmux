import Foundation

func browserNavigationDebugURL(_ url: URL?) -> String {
    guard let url,
          var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
        return "nil"
    }
    components.query = nil
    components.fragment = nil
    return components.string ?? "\(url.scheme ?? "unknown")://\(url.host ?? "")"
}
