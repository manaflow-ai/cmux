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

    @ObservationIgnored private let store: UserDefaults

    static let defaultsKey = "cmux.screenSharing.defaults"
    static let scopeKey = "cmux.screenSharing.scope"

    public init(store: UserDefaults = .standard) {
        self.store = store
        defaults = Self.read(store, key: Self.defaultsKey) ?? ScreenPreferences()
        defaultScope = store.string(forKey: Self.scopeKey).flatMap(SessionScope.init(rawValue:)) ?? .full
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
