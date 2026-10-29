#if os(iOS)
import Foundation
import Observation

/// Browser tabs this iPhone shows in its own web view instead of mirroring the
/// Mac's page ("Open on iPhone" in the tab's page menu). The choice is per tab and
/// stays on this device (across workspace visits and launches) until the person
/// picks "Mirror from <Mac>" or the tab closes. It is view state, like the last
/// opened tab, not a setting: the Mac and its other viewers never see it.
@MainActor
@Observable
public final class NativeBrowserTabs {
    public static let shared = NativeBrowserTabs()

    /// What is kept per tab: where the phone's page is, and the Mac's address it
    /// started from (going back to the mirror carries the phone's address only
    /// when the person browsed away from it).
    struct Entry: Codable, Equatable {
        var url: String?
        var from: String?
    }

    private var entries: [String: Entry]
    @ObservationIgnored private var models: [String: BrowserTabModel] = [:]
    @ObservationIgnored private let defaults: UserDefaults
    static let defaultsKey = "cmuxMobile.browser.nativeTabs"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.defaultsKey),
           let saved = try? JSONDecoder().decode([String: Entry].self, from: data) {
            entries = saved
        } else {
            entries = [:]
        }
    }

    static func key(tab: String, macID: String?) -> String {
        guard let macID, !macID.isEmpty else { return tab }
        return "\(macID)\u{1}\(tab)"
    }

    public func isNative(tab: String, macID: String?) -> Bool {
        entries[Self.key(tab: tab, macID: macID)] != nil
    }

    /// The phone's page of a tab shown on this iPhone (nil: the tab is mirrored).
    public func model(tab: String, macID: String?) -> BrowserTabModel? {
        let key = Self.key(tab: tab, macID: macID)
        guard let entry = entries[key] else { return nil }
        if let model = models[key] { return model }
        // Shown on the phone before this launch: the page opens where it was.
        return makeModel(key: key, url: entry.url.flatMap(URL.init(string:)))
    }

    /// Shows the tab on this iPhone at the Mac's current address.
    @discardableResult
    func open(tab: String, macID: String?, at url: URL?) -> BrowserTabModel {
        let key = Self.key(tab: tab, macID: macID)
        let start = url.flatMap { $0.absoluteString == "about:blank" ? nil : $0 }
        entries[key] = Entry(url: start?.absoluteString, from: start?.absoluteString)
        save()
        if let model = models[key] {
            // Back on the phone after mirroring: the page follows the Mac, keeping
            // the phone's own history behind it.
            if let start, model.url != start { model.load(start) }
            model.clearProblem()
            return model
        }
        return makeModel(key: key, url: start)
    }

    /// Back to the mirror. Returns the address the Mac should go to: the phone's
    /// page when the person browsed away from where it started (or asked the Mac
    /// for an address only it can open), else nil (the Mac's page stays as it is).
    func close(tab: String, macID: String?) -> URL? {
        let key = Self.key(tab: tab, macID: macID)
        guard let entry = entries.removeValue(forKey: key) else { return nil }
        save()
        let model = models[key]
        // The web view stays for the next "Open on iPhone" (its history and scroll),
        // but stops playing or loading behind the mirror.
        model?.pause()
        // A page the phone could not show (the Mac's localhost, an unreachable host): the Mac opens it.
        guard let now = model?.problem?.url ?? model?.url ?? entry.url.flatMap(URL.init(string:)),
              now.absoluteString != entry.from, now.absoluteString != "about:blank" else { return nil }
        return now
    }

    /// The tab closed (or its workspace did): its phone page goes.
    func drop(tab: String, macID: String?) {
        let key = Self.key(tab: tab, macID: macID)
        models.removeValue(forKey: key)
        if entries.removeValue(forKey: key) != nil { save() }
    }

    private func makeModel(key: String, url: URL?) -> BrowserTabModel {
        let model = BrowserTabModel(url: nil, guardsMacAddresses: true)
        model.urlChanged = { [weak self] url in self?.remember(url, for: key) }
        models[key] = model
        if let url { model.load(url) }
        return model
    }

    private func remember(_ url: URL, for key: String) {
        guard var entry = entries[key], entry.url != url.absoluteString else { return }
        entry.url = url.absoluteString
        entries[key] = entry
        save()
    }

    private func save() {
        if entries.isEmpty {
            defaults.removeObject(forKey: Self.defaultsKey)
        } else if let data = try? JSONEncoder().encode(entries) {
            defaults.set(data, forKey: Self.defaultsKey)
        }
    }
}

/// Where an address points, seen from this iPhone: a Mac page's `localhost` is
/// the Mac itself (the phone would load its own), and a tailnet or LAN host may
/// answer the Mac but not the phone.
enum PhoneReach: Equatable {
    /// The phone opens it like any web address.
    case web
    /// A private or tailnet host: the phone tries, and says why when it can't reach it.
    case privateNetwork
    /// The Mac's own loopback: only the mirror can show it.
    case macOnly

    init(_ url: URL?) {
        guard let url, let scheme = url.scheme?.lowercased() else { self = .web; return }
        // file:, view-source:, chrome: and the like are pages of the Mac's browser.
        guard ["http", "https"].contains(scheme) else {
            self = scheme == "about" ? .web : .macOnly
            return
        }
        guard let raw = url.host(percentEncoded: false)?.lowercased(), !raw.isEmpty else { self = .web; return }
        let host = raw.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if host == "localhost" || host.hasSuffix(".localhost") || host == "::1" || host == "0.0.0.0" || host.hasPrefix("127.") {
            self = .macOnly
            return
        }
        let octets = host.split(separator: ".").compactMap { UInt8($0) }
        if octets.count == 4, host.split(separator: ".").count == 4 {
            let (a, b) = (octets[0], octets[1])
            let isPrivate = a == 10 || (a == 172 && (16...31).contains(b)) || (a == 192 && b == 168)
                || (a == 100 && (64...127).contains(b)) || (a == 169 && b == 254)
            self = isPrivate ? .privateNetwork : .web
            return
        }
        if host.contains(":") {
            self = host.hasPrefix("fd") || host.hasPrefix("fc") || host.hasPrefix("fe80") ? .privateNetwork : .web
            return
        }
        let privateSuffixes = [".ts.net", ".local", ".internal", ".lan", ".home.arpa", ".corp", ".intranet"]
        if !host.contains(".") || privateSuffixes.contains(where: host.hasSuffix) {
            self = .privateNetwork
            return
        }
        self = .web
    }
}
#endif
