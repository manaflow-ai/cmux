/// What a phone tab can do with one device. The UI hides what is missing
/// instead of offering a control that fails.
public struct PhoneCapabilities: OptionSet, Sendable, Hashable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let boot = PhoneCapabilities(rawValue: 1 << 0)
    public static let screenshot = PhoneCapabilities(rawValue: 1 << 1)
    public static let recordVideo = PhoneCapabilities(rawValue: 1 << 2)
    public static let deviceLog = PhoneCapabilities(rawValue: 1 << 3)
    public static let openURL = PhoneCapabilities(rawValue: 1 << 4)
    /// Text onto the phone's clipboard.
    public static let pasteboard = PhoneCapabilities(rawValue: 1 << 5)
    /// Taps and swipes from the tab.
    public static let touch = PhoneCapabilities(rawValue: 1 << 6)
    /// Typed keys from the tab.
    public static let keyboard = PhoneCapabilities(rawValue: 1 << 7)
    /// A live frame stream instead of a still after each action.
    public static let liveScreen = PhoneCapabilities(rawValue: 1 << 8)
    /// Hardware buttons (home, lock, volume).
    public static let buttons = PhoneCapabilities(rawValue: 1 << 9)
    /// Light and dark mode.
    public static let appearance = PhoneCapabilities(rawValue: 1 << 10)
    /// A simulated GPS position.
    public static let location = PhoneCapabilities(rawValue: 1 << 11)
    /// The system language and region.
    public static let locale = PhoneCapabilities(rawValue: 1 << 12)
    /// Installing and launching apps.
    public static let apps = PhoneCapabilities(rawValue: 1 << 13)
    /// Turning the screen between portrait and landscape.
    public static let rotate = PhoneCapabilities(rawValue: 1 << 14)
    /// Reading the screen's accessibility tree.
    public static let accessibility = PhoneCapabilities(rawValue: 1 << 15)

    /// The capability names the CLI and MCP report, in a stable order.
    public var names: [String] {
        let all: [(PhoneCapabilities, String)] = [
            (.boot, "boot"), (.screenshot, "screenshot"), (.recordVideo, "record"), (.deviceLog, "log"),
            (.openURL, "open-url"), (.pasteboard, "pasteboard"), (.touch, "touch"), (.keyboard, "keyboard"),
            (.liveScreen, "live"), (.buttons, "buttons"), (.appearance, "appearance"), (.location, "location"),
            (.locale, "locale"), (.apps, "apps"), (.rotate, "rotate"), (.accessibility, "ui"),
        ]
        return all.filter { contains($0.0) }.map(\.1)
    }
}
