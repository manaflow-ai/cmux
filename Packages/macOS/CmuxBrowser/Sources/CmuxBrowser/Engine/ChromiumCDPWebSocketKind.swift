/// CDP websocket path family returned by Chromium discovery.
enum ChromiumCDPWebSocketKind: Sendable {
    case browser
    case page

    func matches(path: String) -> Bool {
        let prefix = switch self {
        case .browser: "/devtools/browser/"
        case .page: "/devtools/page/"
        }
        guard path.hasPrefix(prefix) else { return false }
        let identifier = path.dropFirst(prefix.count)
        return !identifier.isEmpty && !identifier.contains("/")
    }
}
