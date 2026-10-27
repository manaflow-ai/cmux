import Foundation
public import Security

/// The Chief Secure Store (cmux issue 25830, the `sign_in` card): sign-ins a person adds from a
/// Chief's "Secure Store" card, kept in this Mac's login keychain as internet-password items
/// (server = the card's site, label "cmux Secure Store"). The password never enters the
/// conversation or the Chief: the app fills it into the page itself (`browser.page.fill_login`).
/// Every query names our label and comment, so only our own items are ever read or removed.
/// Blocking Keychain calls: callers run them off the main actor. A value with no state: make one
/// where it is used (`ChiefSecureStore().credential(forHost:)`).
public struct ChiefSecureStore: Sendable {
    public init() {}

    public static let label = "cmux Secure Store"
    /// Marks our items apart from any other internet password for the same server.
    public static let comment = "cmux-chief-secure-store-v1"

    public enum Failure: Error, Equatable {
        case invalidSite
        case emptyCredential
        case keychain(OSStatus)
    }

    /// Saves (or replaces) the sign-in for `site` (a DNS name such as `linkedin.com`).
    public func save(site: String, username: String, password: String) throws {
        guard let site = Self.normalized(site) else { throw Failure.invalidSite }
        guard !username.isEmpty, !password.isEmpty else { throw Failure.emptyCredential }
        // One item per site: an older one (another username) goes first.
        let removed = SecItemDelete(Self.query(site: site) as CFDictionary)
        guard removed == errSecSuccess || removed == errSecItemNotFound else { throw Failure.keychain(removed) }
        let add = Self.query(site: site, adding: [kSecAttrAccount as String: username, kSecValueData as String: Data(password.utf8),
                                                  kSecAttrDescription as String: Self.label])
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw Failure.keychain(status) }
    }

    /// Whether the store holds a sign-in for exactly `site`.
    public func contains(site: String) -> Bool {
        guard let site = Self.normalized(site) else { return false }
        let find = Self.query(site: site, adding: [kSecMatchLimit as String: kSecMatchLimitOne, kSecReturnAttributes as String: true])
        var result: CFTypeRef?
        guard SecItemCopyMatching(find as CFDictionary, &result) == errSecSuccess,
              let attributes = result as? [String: Any] else { return false }
        return Self.isOurs(attributes)
    }

    /// The saved sign-in for a page host: the item whose site is the host or a parent domain of it
    /// (`www.linkedin.com` uses `linkedin.com`); the most specific site wins. Nil when none.
    public func credential(forHost host: String) -> (site: String, username: String, password: String)? {
        let sites = self.sites()
        guard let site = Self.bestSite(forHost: host, among: sites) else { return nil }
        let find = Self.query(site: site, adding: [kSecMatchLimit as String: kSecMatchLimitOne, kSecReturnAttributes as String: true,
                                                   kSecReturnData as String: true])
        var result: CFTypeRef?
        guard SecItemCopyMatching(find as CFDictionary, &result) == errSecSuccess,
              let attributes = result as? [String: Any], Self.isOurs(attributes),
              let username: String = Self.value(attributes, kSecAttrAccount),
              let data: Data = Self.value(attributes, kSecValueData),
              let password = String(data: data, encoding: .utf8) else { return nil }
        return (site, username, password)
    }

    /// Removes the sign-in for `site` (no error when there is none).
    public func remove(site: String) throws {
        guard let site = Self.normalized(site) else { throw Failure.invalidSite }
        let status = SecItemDelete(Self.query(site: site) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw Failure.keychain(status) }
    }

    // MARK: Pure rules (tested without a keychain)

    /// A site as stored: lowercased, without a trailing dot; nil unless it is a DNS name
    /// (`[a-z0-9.-]`, 1...253 characters, at least one dot), the `sign_in` card's rule.
    public static func normalized(_ site: String) -> String? {
        var site = site.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if site.hasSuffix(".") { site.removeLast() }
        guard (1...253).contains(site.count), site.contains("."), !site.hasPrefix("."), !site.contains(".."),
              site.unicodeScalars.allSatisfy({ ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "." || $0 == "-" })
        else { return nil }
        return site
    }

    /// Whether a page `host` may use the sign-in of `site`: the same name or a subdomain of it.
    public static func matches(host: String, site: String) -> Bool {
        guard let host = normalized(host), let site = normalized(site) else { return false }
        return host == site || host.hasSuffix("." + site)
    }

    /// The most specific of `sites` that `host` may use (the longest match), or nil.
    public static func bestSite(forHost host: String, among sites: [String]) -> String? {
        sites.filter { matches(host: host, site: $0) }.compactMap(normalized).max { $0.count < $1.count }
    }

    // MARK: Keychain

    /// Our item for `site`, with `extra` attributes or search keys.
    private static func query(site: String, adding extra: [String: Any] = [:]) -> [String: Any] {
        [kSecClass as String: kSecClassInternetPassword, kSecAttrServer as String: site,
         kSecAttrLabel as String: label, kSecAttrComment as String: comment].merging(extra) { _, new in new }
    }

    private static func isOurs(_ attributes: [String: Any]) -> Bool {
        value(attributes, kSecAttrLabel) == label && value(attributes, kSecAttrComment) == comment
    }

    /// An item attribute of type `T` (a lookup that never traps).
    private static func value<T>(_ attributes: [String: Any], _ key: CFString) -> T? {
        attributes.first { $0.key == key as String }?.value as? T
    }

    /// The sites of every sign-in in the store (no passwords read).
    public func sites() -> [String] {
        let find: [String: Any] = [kSecClass as String: kSecClassInternetPassword, kSecAttrLabel as String: Self.label,
                                   kSecAttrComment as String: Self.comment, kSecMatchLimit as String: kSecMatchLimitAll,
                                   kSecReturnAttributes as String: true]
        var result: CFTypeRef?
        guard SecItemCopyMatching(find as CFDictionary, &result) == errSecSuccess,
              let items = result as? [[String: Any]] else { return [] }
        return items.filter(Self.isOurs).compactMap { Self.value($0, kSecAttrServer) }
    }
}

extension ChiefSecureStore {
    /// ``save(site:username:password:)`` off the caller's actor (the keychain blocks); true when saved.
    public func saveInBackground(site: String, username: String, password: String) async -> Bool {
        await Task.detached(priority: .userInitiated) { (try? save(site: site, username: username, password: password)) != nil }.value
    }

    /// ``sites()`` off the caller's actor (the keychain blocks).
    public func sitesInBackground() async -> [String] {
        await Task.detached(priority: .utility) { sites() }.value
    }
}
