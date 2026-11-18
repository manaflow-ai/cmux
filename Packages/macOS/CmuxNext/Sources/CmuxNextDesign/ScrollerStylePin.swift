public import Foundation

/// Pins this process's macOS "Show scroll bars" answer to "When scrolling", so AppKit makes every
/// scroll view an overlay one (SCROLLBARS-THIN: thin, hidden at rest, shown while scrolling).
///
/// With "Always", or with "Automatically" while a mouse is attached (Universal Control's shared
/// mouse included), `NSScroller.preferredScrollerStyle` is `.legacy`: AppKit then gives every new
/// scroll view (SwiftUI's `ScrollView` and `List`, text views, tables, popups) a permanent bar and
/// resets every existing one to it each time a mouse comes or goes. ``SystemScrollers/follow(_:)``
/// fixed only the views that called it, and only after AppKit's reset (Lawrence msg 34125: the
/// Home list's avatar rail kept a bar). The pin goes in the argument domain, the one that outranks
/// the global setting, before anything reads the style: AppKit reads it once and keeps it.
///
/// ```swift
/// ScrollerStylePin().apply(to: .standard) // first thing in main(), before NSApplication
/// ```
///
/// Tests pass a `UserDefaults(suiteName:)` and read the pinned value back.
public struct ScrollerStylePin {
    /// The macOS key behind "Show scroll bars" (`Always`, `WhenScrolling`, absent for `Automatic`).
    public static let key = "AppleShowScrollBars"
    /// The value that makes `NSScroller.preferredScrollerStyle` `.overlay` whatever the devices.
    public static let pinnedValue = "WhenScrolling"

    public init() {}

    /// Puts ``pinnedValue`` under ``key`` in `defaults`' argument domain, keeping its other launch
    /// arguments.
    ///
    /// - Parameter defaults: The defaults AppKit reads (`.standard` in the app).
    /// - Returns: The value `defaults` had before (nil: "Automatically").
    @discardableResult
    public func apply(to defaults: UserDefaults) -> String? {
        let system = defaults.string(forKey: Self.key)
        var arguments = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        arguments[Self.key] = Self.pinnedValue
        // setVolatileDomain refuses a name that is already set: replace the domain whole.
        defaults.removeVolatileDomain(forName: UserDefaults.argumentDomain)
        defaults.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
        return system
    }
}
