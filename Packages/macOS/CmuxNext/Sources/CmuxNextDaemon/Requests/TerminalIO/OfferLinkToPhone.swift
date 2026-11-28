import Foundation

/// `offer-link-to-phone`: a program in terminal `terminalID` asked a browser for `url`
/// (`browser.open_link`). The daemon owns the terminals and the phone's connections, so it
/// decides: when a phone drives the terminal (its last key came from that phone, recently) and
/// the address is public, the phone gets the link and opens it, and ``Response/offered`` is
/// true; the app then opens nothing. Otherwise it is false and the app opens the link as before.
/// A daemon older than this command answers with an error: the app opens it as before too.
public struct OfferLinkToPhoneRequest: DaemonRequest {
    public struct Response: Decodable, Sendable {
        public var offered: Bool
    }

    public static let command = "offer-link-to-phone"
    public var terminalID: String
    public var url: String

    public init(terminalID: String, url: String) {
        self.terminalID = terminalID
        self.url = url
    }
}
