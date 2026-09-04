import Foundation

/// Page-target metadata returned by Chromium's loopback discovery endpoint.
struct ChromiumDiscoveredTarget: Codable, Equatable, Sendable {
    let id: String
    let type: String
    let url: URL?
    let webSocketDebuggerURL: URL?

    init(id: String, type: String, url: URL?, webSocketDebuggerURL: URL?) {
        self.id = id
        self.type = type
        self.url = url
        self.webSocketDebuggerURL = webSocketDebuggerURL
    }
}
