public import Foundation

/// Screen Sharing's machine picker, as Rust decides (`cloud_identity_screen_picker`, cmux-cloud-config
/// `screen_picker`): the new tab ⌄ menu's Screen Sharing ▸ lists every machine this Mac has a viewer
/// for, and a machine that cannot be viewed says why and which side fixes it (Leo, 2026-11-18:
/// "i should be able to see into any connected mac or linux machine", "idk why that was greyed").
public struct ScreenPicker: Sendable, Equatable {
    /// What a row can do now.
    public enum State: String, Sendable, Decodable { case view, sharingOff, notAllowed, offline }
    /// What the host does so the row opens.
    public enum Fix: String, Sendable, Decodable { case shareThisMac, deviceAccess }

    /// One machine's row.
    public struct Row: Sendable, Equatable, Decodable {
        public var id: String
        public var name: String
        /// The SF Symbol the row draws.
        public var symbol: String
        public var state: State
        /// A click opens the screen; else it shows what `fix` needs.
        public var opens: Bool
        public var fix: Fix?
    }

    /// One machine as the picker reads it.
    public struct Machine: Sendable, Equatable, Encodable {
        public var id: String
        public var name: String
        public var platform: String?
        public var online: Bool
        /// Whether `online` is current (this Mac's hub link is up).
        public var onlineKnown: Bool
        public var macScreenShared: Bool
        /// Whether the host lets this Mac ask.
        public var allowsRequests: Bool

        public init(_ device: HubDevice, onlineKnown: Bool, allowsRequests: Bool) {
            id = device.id
            name = device.name
            // A platform this app cannot decode (Windows, a newer one) reads as nil here; it goes to Rust as
            // "unknown", which it does not list, as Settings > Devices offers no screen for it
            // (``HubDevice/hostsScreenThisMacViews``). Rust's absent-is-macOS rule is for older callers.
            platform = device.platform?.rawValue ?? "unknown"
            online = device.online
            self.onlineKnown = onlineKnown
            macScreenShared = device.macScreenShared
            self.allowsRequests = allowsRequests
        }
    }

    public var rows: [Row]

    /// Rust's rows for `machines`. Without an answer from Rust: no rows, so the menu keeps its plain
    /// Screen Sharing row (the Screen Sharing page), as before the picker.
    public static func make(_ machines: [Machine]) -> ScreenPicker {
        struct Request: Encodable { var machines: [Machine] }
        guard let data = try? JSONEncoder().encode(Request(machines: machines)),
              let answer = AppRules.call("cloud_identity_screen_picker", data),
              let rows = try? JSONDecoder().decode([Row].self, from: answer) else { return ScreenPicker(rows: []) }
        return ScreenPicker(rows: rows)
    }
}
