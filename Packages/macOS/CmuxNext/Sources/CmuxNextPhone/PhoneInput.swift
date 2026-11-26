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

    /// The short kind name used in `events.jsonl` ("tap", "swipe", ...), from `cmux-phone-core`'s `input_check`.
    public var kind: String { check(on: PhoneDeviceID(mode: .simulator, raw: "-"), []).kind }

    /// `cmux-phone-core`'s `input_check`: the kind, and whether a phone `id` with `capabilities` takes this input.
    func check(on id: PhoneDeviceID, _ capabilities: PhoneCapabilities) -> (kind: String, allowed: Bool, what: String) {
        let reply = PhoneRules.ask("input_check", ["input": wire, "id": id.description, "capabilities": capabilities.rawValue])
        let kind = reply?["kind"] as? String ?? "input"
        return (kind, reply?["allowed"] as? Bool ?? false, reply?["what"] as? String ?? kind)
    }

    /// The input as `cmux-phone-core`'s `PhoneInput` reads it.
    var wire: [String: Any] {
        switch self {
        case .tap(let point): ["kind": "tap", "x": point.x, "y": point.y]
        case .swipe(let from, let to, let seconds):
            ["kind": "swipe", "from_x": from.x, "from_y": from.y, "to_x": to.x, "to_y": to.y, "seconds": seconds]
        case .text(let text): ["kind": "text", "text": text]
        case .button(let button): ["kind": "button", "button": button.rawValue]
        case .openURL(let url): ["kind": "open_url", "url": url.absoluteString]
        case .pasteboard: ["kind": "pasteboard"]
        case .appearance(let appearance): ["kind": "appearance", "dark": appearance == .dark]
        case .location(let latitude, let longitude): ["kind": "location", "latitude": latitude, "longitude": longitude]
        case .locale(let identifier): ["kind": "locale", "identifier": identifier]
        case .install(let path): ["kind": "install", "path": path.path]
        case .launch(let package): ["kind": "launch", "package": package]
        case .softwareKeyboard: ["kind": "software_keyboard"]
        }
    }

    /// A tap or swipe in `cmux-phone-core`'s wire shape read back; nil for any other.
    init?(touch wire: [String: Any]) {
        func number(_ key: String) -> Double? { (wire[key] as? NSNumber)?.doubleValue }
        switch wire["kind"] as? String {
        case "tap":
            guard let x = number("x"), let y = number("y") else { return nil }
            self = .tap(PhonePoint(x: x, y: y))
        case "swipe":
            guard let fromX = number("from_x"), let fromY = number("from_y"), let toX = number("to_x"), let toY = number("to_y"),
                  let seconds = number("seconds") else { return nil }
            self = .swipe(from: PhonePoint(x: fromX, y: fromY), to: PhonePoint(x: toX, y: toY), seconds: seconds)
        default: return nil
        }
    }
}
