public import CmuxNextDevices
public import Foundation

/// What a Mac Screen page tab shows: the home page or one of the user's
/// devices from the device hub. Its address, `cmux://mac-screen` or
/// `cmux://mac-screen?device=<device id>`, typed in a browser's address bar,
/// opens the page tab. An old `?mac=<id>` record (link pairing, which is
/// gone) still parses, so a restored tab can say links are no longer
/// supported. The record holds only ids, because routes persist and travel
/// with the tree.
///
/// A run's screen link (`acpmux share-host link`) adds `display=<CGDirectDisplayID>`
/// (decimal), optional `control=1` (Full Control; absent is View Only) and
/// `name=<run name>` (a label, never used for routing). Its web form,
/// `https://cmux.com/deeplink/screen?device=&display=`, names the same record
/// (``init(link:linkScheme:)``).
public nonisolated struct MacScreenRecord: Sendable, Hashable {
    public static let scheme = "cmux"
    public static let urlHost = "mac-screen"
    /// The hosts and path of a screen link's web form.
    public static let webHosts: Set<String> = ["cmux.com", "www.cmux.com"]
    public static let webPath = "/deeplink/screen"
    /// The home page.
    public static let homeURL = MacScreenRecord(macID: nil).url

    /// An old link-pairing record's id (no longer supported); nil otherwise.
    public var macID: UUID?
    /// The device hub device this tab shows (its lowercase id); nil otherwise.
    public var deviceID: String?
    /// The device's display a run's link names (a CGDirectDisplayID); nil: the host's default.
    public var display: UInt32?
    /// The link asked for Full Control (`control=1`); otherwise it opens View Only.
    public var control = false
    /// The run's name from its link (shown beside the device's name; never trusted for routing).
    public var name: String?

    public init(macID: UUID?) {
        self.macID = macID
        deviceID = nil
    }

    /// One of the user's devices (the device hub's id).
    public init(deviceID: String, display: UInt32? = nil, control: Bool = false, name: String? = nil) {
        macID = nil
        self.deviceID = Self.normalizedDeviceID(deviceID)
        guard self.deviceID != nil else { return }
        self.display = display
        self.control = control
        self.name = Self.normalizedName(name)
    }

    /// A run's screen link: it names a display. Its tab connects on its own (View Only unless `control`).
    public var isRunLink: Bool { deviceID != nil && display != nil }

    /// The session scope the link asks for.
    public var scope: SessionScope { control ? .full : .view }

    /// The home page: neither a Mac nor a device.
    public var isHome: Bool { macID == nil && deviceID == nil }

    /// The record at `url`; nil for any other address. An unknown or malformed
    /// `mac` or `device` opens the home page; `device` wins over `mac`.
    public init?(url: URL) {
        guard Self.matches(url) else { return nil }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        if let device = items.first(where: { $0.name == "device" })?.value.flatMap(Self.normalizedDeviceID) {
            self.init(device: device, items: items)
            return
        }
        self.init(macID: items.first { $0.name == "mac" }?.value.flatMap(UUID.init(uuidString:)))
    }

    /// A screen link opened from anywhere: `cmux://mac-screen…` (or this
    /// build's `linkScheme`), or the web form
    /// `https://cmux.com/deeplink/screen?device=&display=`. A web link with no
    /// valid device opens the home page. Nil for any other URL.
    public init?(link url: URL, linkScheme: String? = nil) {
        if let linkScheme, linkScheme.lowercased() != Self.scheme, url.scheme?.lowercased() == linkScheme.lowercased(),
           url.host?.lowercased() == Self.urlHost,
           var components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            components.scheme = Self.scheme
            guard let native = components.url else { return nil }
            self.init(url: native)
            return
        }
        if let record = MacScreenRecord(url: url) {
            self = record
            return
        }
        guard Self.isWebLink(url) else { return nil }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        guard let device = items.first(where: { $0.name == "device" })?.value.flatMap(Self.normalizedDeviceID) else {
            self.init(macID: nil)
            return
        }
        self.init(device: device, items: items)
    }

    /// `https://cmux.com/deeplink/screen` (or www.cmux.com), any query.
    public static func isWebLink(_ url: URL?) -> Bool {
        guard let url, url.scheme?.lowercased() == "https", let host = url.host?.lowercased(), webHosts.contains(host) else { return false }
        var path = url.path
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return path == webPath
    }

    /// A device record with a link's display, control and name.
    private init(device: String, items: [URLQueryItem]) {
        let value = { (name: String) in items.first { $0.name == name }?.value }
        self.init(deviceID: device, display: value("display").flatMap(Self.displayID),
                  control: value("control") == "1", name: value("name"))
    }

    public var url: URL {
        var components = URLComponents()
        components.scheme = Self.scheme
        components.host = Self.urlHost
        if let deviceID {
            var items = [URLQueryItem(name: "device", value: deviceID)]
            if let display { items.append(URLQueryItem(name: "display", value: String(display))) }
            if control { items.append(URLQueryItem(name: "control", value: "1")) }
            // A run's name may hold `&`, `=` or `+`: encoded so it stays one value.
            if let name { items.append(URLQueryItem(name: "name", value: name.addingPercentEncoding(withAllowedCharacters: Self.valueAllowed))) }
            components.percentEncodedQueryItems = items
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

    /// What a query value keeps unencoded: the query's characters but the ones that split or change it.
    private static let valueAllowed = CharacterSet.urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&=+#"))

    /// A device id as the hub writes it (a lowercase UUID); nil for anything else.
    static func normalizedDeviceID(_ text: String) -> String? {
        UUID(uuidString: text.trimmingCharacters(in: .whitespaces)).map { $0.uuidString.lowercased() }
    }

    /// A CGDirectDisplayID as a link writes it (decimal, nonzero); nil for anything else.
    static func displayID(_ text: String) -> UInt32? {
        guard !text.isEmpty, text.allSatisfy(\.isASCII), text.allSatisfy(\.isNumber), let id = UInt32(text), id != 0 else { return nil }
        return id
    }

    /// A run's name as a label: trimmed, one line, at most 80 characters; nil when empty.
    static func normalizedName(_ text: String?) -> String? {
        guard let text else { return nil }
        let line = text.components(separatedBy: .newlines).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        return line.isEmpty ? nil : String(line.prefix(80))
    }
}
