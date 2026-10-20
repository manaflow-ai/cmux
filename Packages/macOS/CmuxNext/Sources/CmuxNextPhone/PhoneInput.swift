public import Foundation

/// A point on the phone screen in device points, top-left origin.
public struct PhonePoint: Sendable, Hashable, Codable {
    public var x: Double
    public var y: Double
    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

/// A hardware button.
public enum PhoneButton: String, Sendable, Hashable, Codable, CaseIterable {
    case home, lock, volumeUp = "volume-up", volumeDown = "volume-down", siri
}

/// One thing a person or agent does to the phone. Every input sent through
/// cmux is also logged into an active recording (taps with their points).
public enum PhoneInput: Sendable, Hashable {
    case tap(PhonePoint)
    case swipe(from: PhonePoint, to: PhonePoint, seconds: Double)
    case text(String)
    case button(PhoneButton)
    case openURL(URL)
    /// Puts text on the phone's clipboard (no typing).
    case pasteboard(String)

    /// The capability the backend needs for this input.
    public var requiredCapability: PhoneCapabilities {
        switch self {
        case .tap, .swipe: .touch
        case .text: .keyboard
        case .button: .buttons
        case .openURL: .openURL
        case .pasteboard: .pasteboard
        }
    }

    /// The short kind name used in `events.jsonl` ("tap", "swipe", ...).
    public var kind: String {
        switch self {
        case .tap: "tap"
        case .swipe: "swipe"
        case .text: "text"
        case .button: "button"
        case .openURL: "open-url"
        case .pasteboard: "pasteboard"
        }
    }
}
