public import Foundation

/// A Mac Screen tab: the browser tab record `cmux://mac-screen` (the
/// home page: paired Macs, pairing, Share This Mac) or
/// `cmux://mac-screen?mac=<id>` (one paired Mac's screen). The record holds
/// only the saved Mac's id; its pairing secret stays in the Keychain
/// (`MacScreenStore`), because records persist and travel with the tree.
public nonisolated struct MacScreenRecord: Sendable, Hashable {
    public static let scheme = "cmux"
    public static let urlHost = "mac-screen"
    /// The home page.
    public static let homeURL = MacScreenRecord(macID: nil).url

    /// The saved Mac this tab shows; nil for the home page.
    public var macID: UUID?

    public init(macID: UUID?) {
        self.macID = macID
    }

    /// The record at `url`; nil for any other address. An unknown or malformed
    /// `mac` opens the home page.
    public init?(url: URL) {
        guard Self.matches(url) else { return nil }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        macID = items.first { $0.name == "mac" }?.value.flatMap(UUID.init(uuidString:))
    }

    public var url: URL {
        var components = URLComponents()
        components.scheme = Self.scheme
        components.host = Self.urlHost
        if let macID { components.queryItems = [URLQueryItem(name: "mac", value: macID.uuidString)] }
        return components.url!
    }

    public static func matches(_ url: URL?) -> Bool {
        guard let url else { return false }
        return url.scheme?.lowercased() == scheme && url.host?.lowercased() == urlHost
    }
}
