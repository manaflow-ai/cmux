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

/// A hardware button. `back` and `appSwitch` exist on Android only.
public enum PhoneButton: String, Sendable, Hashable, Codable, CaseIterable {
    case home, lock, volumeUp = "volume-up", volumeDown = "volume-down", siri
    case back, appSwitch = "app-switch"
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
    /// Switches the system between light and dark mode.
    case appearance(PhoneAppearance)
    /// Sets the simulated GPS position.
    case location(latitude: Double, longitude: Double)
    /// Sets the system language and region ("ja_JP"); apps see it on their next launch.
    case locale(String)
    /// Installs an app: a `.app` folder on iOS, an `.apk` on Android.
    case install(URL)
    /// Launches an installed app by its bundle id or package name.
    case launch(String)
    /// Shows or hides the on-screen keyboard (iOS: the simulator's software keyboard toggle).
    case softwareKeyboard

    /// The capability the backend needs for this input.
    public var requiredCapability: PhoneCapabilities {
        switch self {
        case .tap, .swipe: .touch
        case .text: .keyboard
        case .button, .softwareKeyboard: .buttons
        case .openURL: .openURL
        case .pasteboard: .pasteboard
        case .appearance: .appearance
        case .location: .location
        case .locale: .locale
        case .install, .launch: .apps
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
        case .appearance: "appearance"
        case .location: "location"
        case .locale: "locale"
        case .install: "install"
        case .launch: "launch"
        case .softwareKeyboard: "software-keyboard"
        }
    }
}
