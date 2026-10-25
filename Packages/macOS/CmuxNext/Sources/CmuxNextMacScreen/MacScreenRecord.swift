public import Foundation

/// What a Mac Screen page tab shows: the home page or one of the user's
/// devices from the device hub. Its address, `cmux://mac-screen` or
/// `cmux://mac-screen?device=<device id>`, typed in a browser's address bar,
/// opens the page tab. An old `?mac=<id>` record (link pairing, which is
/// gone) still parses, so a restored tab can say links are no longer
/// supported. The record holds only ids, because routes persist and travel
/// with the tree.
public nonisolated struct MacScreenRecord: Sendable, Hashable {
    public static let scheme = "cmux"
    public static let urlHost = "mac-screen"
    /// The home page.
    public static let homeURL = MacScreenRecord(macID: nil).url

    /// An old link-pairing record's id (no longer supported); nil otherwise.
    public var macID: UUID?
    /// The device hub device this tab shows (its lowercase id); nil otherwise.
    public var deviceID: String?

    public init(macID: UUID?) {
        self.macID = macID
        deviceID = nil
    }

    /// One of the user's devices (the device hub's id).
    public init(deviceID: String) {
        macID = nil
        self.deviceID = Self.normalizedDeviceID(deviceID)
    }

    /// The home page: neither a Mac nor a device.
    public var isHome: Bool { macID == nil && deviceID == nil }

    /// The record at `url`; nil for any other address. An unknown or malformed
    /// `mac` or `device` opens the home page; `device` wins over `mac`.
    public init?(url: URL) {
        guard Self.matches(url) else { return nil }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        if let device = items.first(where: { $0.name == "device" })?.value.flatMap(Self.normalizedDeviceID) {
            macID = nil
            deviceID = device
            return
        }
        macID = items.first { $0.name == "mac" }?.value.flatMap(UUID.init(uuidString:))
        deviceID = nil
    }

    public var url: URL {
        var components = URLComponents()
        components.scheme = Self.scheme
        components.host = Self.urlHost
        if let deviceID {
            components.queryItems = [URLQueryItem(name: "device", value: deviceID)]
        } else if let macID {
            components.queryItems = [URLQueryItem(name: "mac", value: macID.uuidString)]
        }
        // A scheme, a host and query items always form a URL; /dev/null only stands in for the type checker.
        return components.url ?? URL(fileURLWithPath: "/dev/null")
    }

    public static func matches(_ url: URL?) -> Bool {
        guard let url else { return false }
        return url.scheme?.lowercased() == scheme && url.host?.lowercased() == urlHost
    }

    /// A device id as the hub writes it (a lowercase UUID); nil for anything else.
    static func normalizedDeviceID(_ text: String) -> String? {
        UUID(uuidString: text.trimmingCharacters(in: .whitespaces)).map { $0.uuidString.lowercased() }
    }
}
