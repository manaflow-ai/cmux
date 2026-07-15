import Foundation

/// An unsolicited event received from a Chrome DevTools Protocol session.
struct CDPEvent: Sendable {
    let method: String
    let parameters: [String: CDPJSONValue]
    let sessionID: String?
}
