import Foundation

#if DEBUG
extension AppDelegate {
    static func authURLDebugSummary(_ url: URL) -> String {
        let scheme = url.scheme ?? "nil"
        let target = url.host ?? url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let queryItems = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.map(\.name).joined(separator: ",") ?? ""
        return "\(scheme):\(target.isEmpty ? "nil" : target):\(queryItems.isEmpty ? "none" : queryItems)"
    }
}
#endif
