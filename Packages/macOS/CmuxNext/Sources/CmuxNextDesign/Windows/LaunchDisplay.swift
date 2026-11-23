public import AppKit

/// The display a tagged dev build opens its shell windows on (#51115), so a build an agent
/// launches lands on the Mac's built-in display, never on the external display the person keeps
/// for their own work. `CMUX_NEXT_LAUNCH_DISPLAY`:
///
/// - `builtin`: the built-in display. The default of a tagged dev build, however it is opened
///   (`reload-cloud.sh --launch`, the Tag Opener, Finder).
/// - `main`: the menu-bar display.
/// - `<n>`: `NSScreen.screens[n]` (0 is the menu-bar screen; past the end, the last one).
/// - `off` (or any other value): the usual placement. The default of nightly and stable.
///
/// A window whose frame is already on that display keeps it; any other (a new window, one saved
/// on another display) is centered there, inside its visible frame. A Mac without that display
/// (a Mac mini, a closed lid) keeps the usual placement. An agent screenshot launch
/// (`CMUX_NEXT_TEST_WINDOW_SCREEN`) places its windows by its own rule instead.
public enum LaunchDisplay: Sendable, Equatable {
    case builtIn
    case index(Int)

    public nonisolated static let environmentKey = "CMUX_NEXT_LAUNCH_DISPLAY"

    /// Set by the App at launch; nil when windows keep the usual placement.
    @MainActor public static var current: LaunchDisplay?

    /// `value` of ``environmentKey``; unset or empty means `builtin` for a tagged dev build and
    /// `off` otherwise.
    public nonisolated static func parse(_ value: String?, isDevBuild: Bool) -> LaunchDisplay? {
        switch value?.trimmingCharacters(in: .whitespaces).lowercased() ?? "" {
        case "": return isDevBuild ? .builtIn : nil
        case "builtin", "built-in", "internal": return .builtIn
        case "main": return .index(0)
        case let other: return Int(other).flatMap { $0 >= 0 ? .index($0) : nil }
        }
    }

    /// The index of the display this names in `screens` (whether each is built in), nil when
    /// none is connected.
    public nonisolated func screenIndex(builtIn screens: [Bool]) -> Int? {
        guard !screens.isEmpty else { return nil }
        switch self {
        case .builtIn: return screens.firstIndex(of: true)
        case .index(let index): return min(max(index, 0), screens.count - 1)
        }
    }

    /// Where a shell window opens, `frame` being its saved AppKit frame (nil for a new window of
    /// `defaultSize`) and `screens` each display's visible frame: `frame` kept inside the launch
    /// display when its title bar is on it, else centered there, moved by `cascade` steps. Nil
    /// when the display is not connected: the caller keeps its own placement.
    public nonisolated func frame(_ frame: CGRect?, defaultSize: CGSize, cascade: Int = 0,
                                  screens: [(isBuiltIn: Bool, visible: CGRect)]) -> CGRect? {
        guard let index = screenIndex(builtIn: screens.map(\.isBuiltIn)) else { return nil }
        let visible = screens[index].visible
        if let frame, WindowPlacement.canGrabTitleBar(of: frame, on: visible) { return WindowPlacement.contain(frame, in: visible) }
        return WindowPlacement.frame(size: frame?.size ?? defaultSize, parentFrame: nil, visible: visible, cascade: cascade)
    }

    // MARK: AppKit

    /// ``frame(_:defaultSize:cascade:screens:)`` for ``current`` on today's displays; nil when
    /// ``current`` is nil or its display is not connected.
    @MainActor public static func placed(_ frame: CGRect?, defaultSize: CGSize, cascade: Int = 0) -> CGRect? {
        guard let current else { return nil }
        let screens = NSScreen.screens.map { (isBuiltIn: isBuiltIn($0), visible: $0.visibleFrame) }
        return current.frame(frame, defaultSize: defaultSize, cascade: cascade, screens: screens)
    }

    /// Whether `screen` is the Mac's own display.
    @MainActor public static func isBuiltIn(_ screen: NSScreen) -> Bool {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return false }
        return CGDisplayIsBuiltin(number.uint32Value) != 0
    }
}
