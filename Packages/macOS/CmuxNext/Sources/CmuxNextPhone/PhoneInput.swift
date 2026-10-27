public import Foundation

/// A point on the phone screen in device points, top-left origin.
public struct PhonePoint: Sendable, Hashable, Codable {
    public var x: Double
    public var y: Double
    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    /// Both coordinates are finite and within ``PhoneRecording/maxMagnitude``.
    var isPlausible: Bool { PhoneRecording.isPlausible(x) && PhoneRecording.isPlausible(y) }
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

    /// The longest swipe cmux sends, in seconds: far past any real gesture, and short enough
    /// that its 16 ms touch steps stay a short list.
    public static let longestSwipe = 60.0

    /// Throws when a point or a swipe time is one no screen or gesture has: a point that is not
    /// finite or is past ``PhoneRecording/maxMagnitude`` (``PhoneError/outsideScreen``), or a swipe
    /// time outside 0...``longestSwipe`` (``PhoneError/outOfRange(what:)``). Socket and CLI
    /// arguments reach here, so the service and every backend check it before an input is
    /// recorded or turned into whole pixels and milliseconds.
    public func validate() throws {
        switch self {
        case .tap(let point):
            guard point.isPlausible else { throw PhoneError.outsideScreen }
        case .swipe(let from, let to, let seconds):
            guard from.isPlausible, to.isPlausible else { throw PhoneError.outsideScreen }
            guard (0...Self.longestSwipe).contains(seconds) else { throw PhoneError.outOfRange(what: "the swipe's seconds") }
        case .text, .button, .openURL, .pasteboard, .appearance, .location, .locale, .install, .launch, .softwareKeyboard:
            return
        }
    }

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
