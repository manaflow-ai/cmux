#if os(iOS)
import CmuxMobileBrowserStream
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

    /// What is kept per tab: where the phone's page is, and whether the person
    /// browsed there (typed an address, followed a link, went back or forward).
    /// Going back to the mirror carries the phone's address only then: a redirect
    /// the phone's page took by itself (a mobile site, a sign-in page for a phone
    /// with no session) must never move the Mac's signed-in page.
    struct Entry: Codable, Equatable {
        var url: String?
        var browsed = false
    }

    /// The tabs shown on the phone: the one observed state (a page or toolbar
    /// re-renders when a tab flips; where the page is changes nothing they show).
    private var nativeKeys: Set<String>
    @ObservationIgnored private var entries: [String: Entry]
    @ObservationIgnored private var models: [String: BrowserTabModel] = [:]
    /// The `localhost` ports each tab opened: they stay forwarded until the tab
    /// mirrors or closes (a sign-in round trip through another site comes back).
    @ObservationIgnored private var tabPorts: [String: Set<UInt16>] = [:]
    @ObservationIgnored private let defaults: UserDefaults
    static let defaultsKey = "cmuxMobile.browser.nativeTabs"
    /// Forwards a tab's `localhost:<port>` page to its Mac's loopback (nil: those
    /// pages stay on the Mac).
    @ObservationIgnored public var forwarder: LocalhostForwarder?
    /// Whether a Mac serves `localhost` (its `version` says `localhost-forward-v1`).
    @ObservationIgnored public var macForwardsLocalhost: @MainActor (_ macID: String?) -> Bool = { _ in false }
    public static let forwardCapability = "localhost-forward-v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.defaultsKey),
           let saved = try? JSONDecoder().decode([String: Entry].self, from: data) {
            entries = saved
        } else {
            entries = [:]
        }
        nativeKeys = Set(entries.keys)
    }

    static func key(tab: String, macID: String?) -> String {
        guard let macID, !macID.isEmpty else { return tab }
        return "\(macID)\u{1}\(tab)"
    }

    static func tab(ofKey key: String) -> String {
        key.split(separator: "\u{1}", maxSplits: 1).last.map(String.init) ?? key
    }

    static func macID(ofKey key: String) -> String? {
        let pieces = key.split(separator: "\u{1}", maxSplits: 1)
        return pieces.count == 2 ? String(pieces[0]) : nil
    }

    /// Whether a Mac's `localhost` pages can open on this iPhone.
    func canForward(macID: String?) -> Bool {
        forwarder != nil && macForwardsLocalhost(macID)
    }

    /// Whether `url` (a Mac `localhost:<port>` page) may load in the tab `key`.
    private func loopbackPolicy(_ url: URL, key: String) -> BrowserTabModel.LoopbackForward {
        let macID = Self.macID(ofKey: key)
        guard forwarder != nil, let port = PhoneReach.port(url) else { return .macOnly(detail: nil) }
        guard macForwardsLocalhost(macID) else {
            return .macOnly(detail: String(localized: "Update cmux on the Mac to open its localhost pages on this iPhone. The mirrored page can show it now."))
        }
        // One port, one Mac: the port forwards to another Mac whose tab on this iPhone
        // still shows it (a tab that was refused the port never holds it).
        let owner = forwarder?.forwardsElsewhere(port, than: macID) == true
        let shownThere = nativeKeys.contains { other in
            other != key && Self.macID(ofKey: other) != macID && models[other]?.problem == nil
                && entries[other]?.url.flatMap(URL.init(string:)).flatMap(PhoneReach.port) == port
        }
        if owner && shownThere {
            return .macOnly(detail: String(localized: "Another Mac's tab on this iPhone shows localhost:\(port). Mirror this one, or close that tab first."))
        }
        return .forwarded
    }

    /// Readies `url`'s port on this iPhone, forwarded to the Mac of the tab `key`.
    private func forward(_ url: URL, key: String) async -> BrowserTabModel.LoopbackForward {
        guard case .forwarded = loopbackPolicy(url, key: key), let forwarder, let port = PhoneReach.port(url) else {
            return loopbackPolicy(url, key: key)
        }
        do throws(LocalhostForwarder.Failure) {
            try await forwarder.forward(port: port, macID: Self.macID(ofKey: key))
            // The tab closed or mirrored while the port was starting: nothing keeps it.
            guard nativeKeys.contains(key) else {
                retainPorts()
                return .forwarded
            }
            tabPorts[key, default: []].insert(port)
            return .forwarded
        } catch .portInUse {
            return .macOnly(detail: String(localized: "Another app on this iPhone uses port \(port), so the mirrored page has to show it."))
        } catch {
            return .macOnly(detail: nil)
        }
    }

    /// Stops forwarding ports no tab on this iPhone shows any more.
    private func retainPorts() {
        guard let forwarder else { return }
        tabPorts = tabPorts.filter { nativeKeys.contains($0.key) }
        let shown = nativeKeys.compactMap { entries[$0]?.url.flatMap(URL.init(string:)).flatMap(PhoneReach.port) }
        forwarder.retain(ports: Set(shown).union(tabPorts.values.joined()))
    }

    public func isNative(tab: String, macID: String?) -> Bool {
        nativeKeys.contains(Self.key(tab: tab, macID: macID))
    }

    /// The phone's page of a tab shown on this iPhone (nil: the tab is mirrored).
    public func model(tab: String, macID: String?) -> BrowserTabModel? {
        let key = Self.key(tab: tab, macID: macID)
        guard nativeKeys.contains(key) else { return nil }
        if let model = models[key] { return model }
        // Shown on the phone before this launch: the page opens where it was.
        return makeModel(key: key, url: entries[key]?.url.flatMap(URL.init(string:)))
    }

    /// Shows the tab on this iPhone at the Mac's current address.
    @discardableResult
    func open(tab: String, macID: String?, at url: URL?) -> BrowserTabModel {
        let key = Self.key(tab: tab, macID: macID)
        let start = url.flatMap { $0.absoluteString == "about:blank" ? nil : $0 }
        entries[key] = Entry(url: start?.absoluteString)
        nativeKeys.insert(key)
        save()
        if let model = models[key] {
            // Back on the phone after mirroring: the page follows the Mac, keeping
            // the phone's own history behind it.
            model.clearProblem()
            if let start, model.url != start { model.load(start) }
            return model
        }
        return makeModel(key: key, url: start)
    }

    /// Back to the mirror. Returns the address the Mac should go to: the phone's
    /// page (or the address the phone could not show) when the person browsed,
    /// else nil (the Mac's page stays as it is).
    func close(tab: String, macID: String?) -> URL? {
        let key = Self.key(tab: tab, macID: macID)
        guard let entry = entries.removeValue(forKey: key) else { return nil }
        nativeKeys.remove(key)
        save()
        let model = models[key]
        // Read before pausing: stopping a load puts the web view back on the last page.
        let now = model?.problem?.url ?? model?.url ?? entry.url.flatMap(URL.init(string:))
        // The web view stays for the next "Open on iPhone" (its history and scroll),
        // but stops playing or loading behind the mirror.
        model?.pause()
        retainPorts()
        guard entry.browsed, let now, now.absoluteString != "about:blank" else { return nil }
        return now
    }

    /// The tab closed (or its workspace did): its phone page goes.
    func drop(tab: String, macID: String?) {
        forget(Self.key(tab: tab, macID: macID))
    }

    /// The tabs the Macs list now: pages of tabs closed elsewhere (on the Mac, by
    /// another viewer) go, with their web views.
    public func retain(tabs: Set<String>) {
        for key in Array(nativeKeys) where !tabs.contains(Self.tab(ofKey: key)) { forget(key) }
    }

    /// A new workspace's placeholder tab became the Mac's real tab.
    public func rename(tab old: String, to new: String) {
        guard old != new else { return }
        for key in Array(nativeKeys) where Self.tab(ofKey: key) == old {
            let next = key.replacingOccurrences(of: old, with: new, options: [.anchored, .backwards])
            entries[next] = entries.removeValue(forKey: key)
            models[next] = models.removeValue(forKey: key)
            tabPorts[next] = tabPorts.removeValue(forKey: key)
            nativeKeys.remove(key)
            nativeKeys.insert(next)
            if let model = models[next] { observe(model, key: next) }
        }
        save()
    }

    private func forget(_ key: String) {
        models.removeValue(forKey: key)?.pause()
        nativeKeys.remove(key)
        if entries.removeValue(forKey: key) != nil { save() }
        retainPorts()
    }

    private func makeModel(key: String, url: URL?) -> BrowserTabModel {
        let model = BrowserTabModel(url: nil, guardsMacAddresses: true)
        observe(model, key: key)
        models[key] = model
        if let url { model.load(url) }
        return model
    }

    private func observe(_ model: BrowserTabModel, key: String) {
        model.urlChanged = { [weak self] url in self?.remember(url, for: key) }
        model.personNavigated = { [weak self] in self?.noteBrowsed(key) }
        model.loopbackPolicy = { [weak self] url in
            self?.loopbackPolicy(url, key: key) ?? .macOnly(detail: nil)
        }
        model.forwardLoopback = { [weak self] url in
            await self?.forward(url, key: key) ?? .macOnly(detail: nil)
        }
        model.loopbackIsOpen = { [weak self] url in
            guard let self, let port = PhoneReach.port(url) else { return false }
            return self.forwarder?.ports.contains(port) == true
        }
        model.loopbackRefusal = { [weak self] url in
            PhoneReach.port(url).flatMap { self?.forwarder?.refusals[$0] }
        }
    }

    private func remember(_ url: URL, for key: String) {
        guard var entry = entries[key], entry.url != url.absoluteString else { return }
        entry.url = url.absoluteString
        entries[key] = entry
        save()
        retainPorts()
    }

    private func noteBrowsed(_ key: String) {
        guard var entry = entries[key], !entry.browsed else { return }
        entry.browsed = true
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
    /// A page of the Mac's own browser (`file:`, `view-source:`): only the mirror can show it.
    case macOnly
    /// A web page on the Mac's loopback (`localhost:<port>`): forwarded to the Mac when
    /// it serves `localhost`, else only the mirror can show it.
    case macLoopback

    /// The loopback port of a `localhost` page.
    static func port(_ url: URL) -> UInt16? {
        guard PhoneReach(url) == .macLoopback else { return nil }
        if let port = url.port { return port == 0 ? nil : UInt16(exactly: port) }
        return url.scheme?.lowercased() == "https" ? 443 : 80
    }

    static let macSchemes: Set<String> = ["file", "view-source", "chrome", "chrome-extension", "devtools"]

    init(_ url: URL?) {
        guard let url, let scheme = url.scheme?.lowercased() else { self = .web; return }
        // Pages of the Mac's own browser. Other schemes (mailto:, tel:, an app's
        // link) are for this iPhone: the page hands them to iOS.
        guard ["http", "https"].contains(scheme) else {
            self = Self.macSchemes.contains(scheme) ? .macOnly : .web
            return
        }
        guard let raw = url.host(percentEncoded: false)?.lowercased(), !raw.isEmpty else { self = .web; return }
        let host = raw.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        // What this iPhone can listen on for the Mac: `localhost`, `127.0.0.1`, `[::1]`.
        if host == "localhost" || host == "127.0.0.1" || host == "::1" {
            self = .macLoopback
            return
        }
        // Other loopback names and addresses: only the Mac's browser opens them.
        if host.hasSuffix(".localhost") || host == "0.0.0.0" || host.hasPrefix("127.") {
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
