import Foundation
import Observation

/// The link transport (PROTOCOL.md "Transport switch", verify/hybrid-link.md).
/// WireGuard (the default) carries the link and opens a WebRTC media session
/// beside it for browser video; WebRTC carries everything on one peer
/// connection. The picker lists WireGuard first.
public enum TransportKind: String, CaseIterable, Identifiable, Sendable, Codable {
    case wireguard
    case webrtc

    public var id: String { rawValue }

    /// The short name (the Settings root's value, the status line).
    public var title: String {
        switch self {
        case .webrtc: "WebRTC only"
        case .wireguard: "WireGuard"
        }
    }

    /// The Transport page's row title.
    public var pickerTitle: String {
        switch self {
        case .webrtc: String(localized: "WebRTC only")
        case .wireguard: String(localized: "WireGuard (recommended)")
        }
    }

    /// The Settings root's value with the Developer dial policies that apply
    /// to this transport: Block UDP is a WireGuard policy (WebRTC ignores it,
    /// PROTOCOL.md "Transport switch"), Relay only applies to both.
    public func settingsValue(blockUDP: Bool, relayOnly: Bool) -> String {
        if blockUDP, self == .wireguard { return "\(title), UDP blocked" }
        if relayOnly { return "\(title), relay only" }
        return title
    }

    /// The transport of an install with no saved choice.
    public static let fallback: TransportKind = .wireguard
}

/// The system notification permission as Settings shows it.
public enum NotificationPermission: Sendable, Equatable {
    case notDetermined, on, off

    /// "On", "Off" or "Not set" (the Notifications page's permission row).
    public var title: String {
        switch self {
        case .on: "On"
        case .off: "Off"
        case .notDetermined: "Not set"
        }
    }

    /// The Settings root's trailing value for Notifications. A build without
    /// push gets only Chief's local alerts, so "On" there reads "Chief only".
    public func rootValue(push: Bool) -> String {
        guard !push, self == .on else { return title }
        return "Chief only"
    }
}

/// App appearance override.
/// Settings → Notifications: which Mac events reach this phone (PROTOCOL.md
/// "Push notifications", `kinds`).
public enum NotificationLevel: String, CaseIterable, Identifiable, Sendable, Codable {
    /// Questions and permissions.
    case needed
    /// Those, finished turns and Chief (the default).
    case neededAndFinished
    /// Those, errors and terminal notifications.
    case everything

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .needed: String(localized: "Only when I'm needed")
        case .neededAndFinished: String(localized: "Needed and finished")
        case .everything: String(localized: "Everything")
        }
    }

    public var detail: String {
        switch self {
        case .needed: String(localized: "Questions and permission requests.")
        case .neededAndFinished: String(localized: "Also finished tasks and Chief's replies.")
        case .everything: String(localized: "Also errors and notifications from programs in your terminals.")
        }
    }

    /// The event kinds the phone registers for.
    public var kinds: [String] {
        switch self {
        case .needed: ["question", "permission"]
        case .neededAndFinished: ["question", "permission", "completed", "chief"]
        case .everything: ["question", "permission", "completed", "chief", "failed", "terminal"]
        }
    }
}

public enum AppearanceMode: String, CaseIterable, Identifiable, Sendable, Codable {
    case light, dark, system

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .light: "Light"
        case .dark: "Dark"
        case .system: "System"
        }
    }
}

/// What to do with text sent while an agent is still working.
public enum FollowUpBehavior: String, CaseIterable, Identifiable, Sendable, Codable {
    case queue, steer

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .queue: "Queue"
        case .steer: "Steer"
        }
    }
}

/// Device-local preferences (SPEC section 9), persisted in `UserDefaults`.
@MainActor
@Observable
public final class SettingsStore {
    @ObservationIgnored private let defaults: UserDefaults

    public var transport: TransportKind { didSet { save(transport.rawValue, "transport") } }
    public var appearance: AppearanceMode { didSet { save(appearance.rawValue, "appearance") } }
    /// Read by `CmuxMobileHaptics` through the same key.
    public var hapticsEnabled: Bool { didSet { save(hapticsEnabled, "hapticsEnabled") } }
    /// Read by the terminal (`CmuxMobilePreferences.terminalFontSize`) through the same key.
    public var terminalFontSize: Int { didSet { save(terminalFontSize, "terminalFontSize") } }
    /// Read by the agent composer (`CmuxMobilePreferences`) through the same key.
    public var dismissKeyboardAfterSend: Bool { didSet { save(dismissKeyboardAfterSend, "dismissKeyboardAfterSend") } }
    /// Read by the agent composer: Steer sends a message typed while the
    /// agent works as acpmux `steer`, Queue sends it after the turn.
    public var followUp: FollowUpBehavior { didSet { save(followUp.rawValue, "followUp") } }
    /// Read by code cards, edit previews and the diff viewer.
    public var wrapCode: Bool { didSet { save(wrapCode, "wrapCode") } }
    /// Read by the terminal key bar.
    public var keyClicks: Bool { didSet { save(keyClicks, "keyClicks") } }
    public var notifyLevel: NotificationLevel { didSet { save(notifyLevel.rawValue, "notifyLevel") } }
    /// Macs whose notifications are off (their device ids).
    public private(set) var notifyMutedMacs: [String] { didSet { save(notifyMutedMacs, "notifyMutedMacs") } }
    /// Show previews: off, the lock screen shows only the kind and the Mac.
    public var notifyPreviews: Bool { didSet { save(notifyPreviews, "notifyPreviews") } }
    public var requireFaceID: Bool { didSet { save(requireFaceID, "requireFaceID") } }

    /// The terminal's key row zooms by writing the font size directly.
    @ObservationIgnored private var defaultsObserver: (any NSObjectProtocol)?

    /// The key row's zoom keys changed the size: show it (no write back).
    private func reloadTerminalFontSize() {
        let stored = defaults.object(forKey: "cmuxMobile.settings.terminalFontSize") as? Int ?? Self.defaultTerminalFontSize
        if stored != terminalFontSize { terminalFontSize = stored }
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        func string(_ key: String) -> String? { defaults.string(forKey: "cmuxMobile.settings.\(key)") }
        func bool(_ key: String, _ fallback: Bool) -> Bool { defaults.object(forKey: "cmuxMobile.settings.\(key)") as? Bool ?? fallback }
        // A saved choice stays; an install that never chose gets WireGuard
        // (it used to get WebRTC; verify/hybrid-link.md).
        transport = string("transport").flatMap(TransportKind.init(rawValue:)) ?? .fallback
        appearance = string("appearance").flatMap(AppearanceMode.init(rawValue:)) ?? .system
        hapticsEnabled = bool("hapticsEnabled", true)
        terminalFontSize = defaults.object(forKey: "cmuxMobile.settings.terminalFontSize") as? Int ?? Self.defaultTerminalFontSize
        dismissKeyboardAfterSend = bool("dismissKeyboardAfterSend", true)
        followUp = string("followUp").flatMap(FollowUpBehavior.init(rawValue:)) ?? .queue
        wrapCode = bool("wrapCode", false)
        keyClicks = bool("keyClicks", true)
        // The earlier three switches: Finished off reads as "Only when I'm needed".
        let level = string("notifyLevel").flatMap(NotificationLevel.init(rawValue:))
            ?? (bool("notifyFinished", true) ? .neededAndFinished : .needed)
        notifyLevel = level
        // Saved now: the earlier switches are retired below.
        defaults.set(level.rawValue, forKey: "cmuxMobile.settings.notifyLevel")
        notifyMutedMacs = defaults.stringArray(forKey: "cmuxMobile.settings.notifyMutedMacs") ?? []
        notifyPreviews = bool("notifyPreviews", true)
        requireFaceID = bool("requireFaceID", false)
        defaultsObserver = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: defaults, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reloadTerminalFontSize() }
        }
        // Retired settings that never took effect (a terminal theme the phone
        // cannot read from the Mac, and a connection-details switch).
        for key in Self.retiredKeys { defaults.removeObject(forKey: "cmuxMobile.settings.\(key)") }
    }

    static let retiredKeys = ["showConnectionDetails", "terminalTheme", "notifyQuestions", "notifyFinished", "notifyErrors"]

    /// Whether this Mac's notifications are on.
    public func notifies(macID: String) -> Bool { !notifyMutedMacs.contains(macID) }

    /// Turns one Mac's notifications on or off.
    public func setNotifications(macID: String, on: Bool) {
        if on {
            notifyMutedMacs.removeAll { $0 == macID }
        } else if !notifyMutedMacs.contains(macID) {
            notifyMutedMacs.append(macID)
        }
    }

    /// The terminal's built-in size (`CmuxMobilePreferences.defaultTerminalFontSize`).
    public static let defaultTerminalFontSize = 12

    private func save(_ value: Any, _ key: String) {
        defaults.set(value, forKey: "cmuxMobile.settings.\(key)")
    }
}
