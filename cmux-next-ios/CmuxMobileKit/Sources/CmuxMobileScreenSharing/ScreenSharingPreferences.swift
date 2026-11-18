#if os(iOS)
public import CmuxDeviceHub
public import CmuxScreenKit
public import Foundation
public import Observation

/// The person's Screen Sharing choices on this phone (Settings → Screen
/// Sharing): the viewer's choices every session starts with, and what Connect
/// asks for. One set for every Mac, so a change in Settings or in a session's
/// menu applies to the next session with any Mac.
@MainActor @Observable
public final class ScreenSharingPreferences {
    /// The viewer's choices: input mode, quality, stats, fit.
    public var defaults: ScreenPreferences { didSet { write(defaults, key: Self.defaultsKey) } }
    /// What Connect asks for: Full Control (see and control) or View Only.
    public var defaultScope: SessionScope {
        didSet { store.set(defaultScope.rawValue, forKey: Self.scopeKey) }
    }

    /// The Macs the list last read and the account it read them for, so the next showing draws
    /// them in its first frame instead of "Finding your Macs…" (conn-quiet). Only that account's
    /// showing draws them; signing out forgets them.
    public private(set) var lastMacs: LastMacs?

    /// A read Macs list, kept for the account that read it.
    public struct LastMacs: Codable, Equatable, Sendable {
        public var account: String
        public var macs: [HubDevice]
    }

    @ObservationIgnored private let store: UserDefaults

    static let defaultsKey = "cmux.screenSharing.defaults"
    static let scopeKey = "cmux.screenSharing.scope"
    static let lastMacsKey = "cmux.screenSharing.lastMacs"

    public init(store: UserDefaults = .standard) {
        self.store = store
        defaults = Self.read(store, key: Self.defaultsKey) ?? ScreenPreferences()
        defaultScope = store.string(forKey: Self.scopeKey).flatMap(SessionScope.init(rawValue:)) ?? .full
        lastMacs = store.data(forKey: Self.lastMacsKey).flatMap { try? JSONDecoder().decode(LastMacs.self, from: $0) }
    }

    /// The Macs `account`'s last read list held; none for another account or no account.
    func lastMacs(for account: String?) -> [HubDevice] {
        guard let account, !account.isEmpty, let lastMacs, lastMacs.account == account else { return [] }
        return lastMacs.macs
    }

    /// Keeps the Macs a read list holds for `account`'s next showing (written only when they changed).
    func rememberMacs(_ macs: [HubDevice], for account: String?) {
        guard let account, !account.isEmpty else { return }
        let next = LastMacs(account: account, macs: macs)
        guard next != lastMacs, let data = try? JSONEncoder().encode(next) else { return }
        lastMacs = next
        store.set(data, forKey: Self.lastMacsKey)
    }

    /// Signed out: the account's Macs are no longer this phone's to show.
    func forgetMacs() {
        lastMacs = nil
        store.removeObject(forKey: Self.lastMacsKey)
    }

    /// The choices a session with `hostID` starts with.
    public func screen(for _: String) -> ScreenPreferences { defaults }

    /// Keeps a session's choices (its menu changed them) for the next one.
    public func save(_ preferences: ScreenPreferences, for _: String) {
        if preferences != defaults { defaults = preferences }
    }

    private func write(_ preferences: ScreenPreferences, key: String) {
        guard let data = try? JSONEncoder().encode(preferences) else { return }
        store.set(data, forKey: key)
    }

    private static func read(_ store: UserDefaults, key: String) -> ScreenPreferences? {
        store.data(forKey: key).flatMap { try? JSONDecoder().decode(ScreenPreferences.self, from: $0) }
    }
}
#endif
