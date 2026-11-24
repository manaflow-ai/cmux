import Foundation

/// `tabs.newTabClock.*` in cmux-next.json: the New Tab clock, a large stylized time over the composer
/// in the font, weight and color the person picks (webviews newtab/NewTabClock.tsx). Off by default
/// (`show`). The web New Tab page gets it in its handshake (`newTab.clock`); the native New Tab page
/// does not draw it.
public nonisolated struct NewTabClockSetting: Sendable, Equatable {
    public var font: NewTabClockFont
    public var weight: NewTabClockWeight
    public var color: NewTabClockColor
    /// The date line over the time.
    public var date: Bool

    public init(font: NewTabClockFont = fontDefault, weight: NewTabClockWeight = weightDefault,
                color: NewTabClockColor = colorDefault, date: Bool = dateDefault) {
        self.font = font
        self.weight = weight
        self.color = color
        self.date = date
    }

    /// The clock `root` asks for, nil when `show` is off or unset. A value that is no choice reads as
    /// its default (the schema check reports it).
    public static func clock(in root: JSONValue) -> NewTabClockSetting? {
        guard root.value(at: showPath)?.boolValue ?? showDefault else { return nil }
        return NewTabClockSetting(
            font: root.value(at: fontPath)?.stringValue.flatMap(NewTabClockFont.init(rawValue:)) ?? fontDefault,
            weight: root.value(at: weightPath)?.stringValue.flatMap(NewTabClockWeight.init(rawValue:)) ?? weightDefault,
            color: root.value(at: colorPath)?.stringValue.flatMap(NewTabClockColor.init(rawValue:)) ?? colorDefault,
            date: root.value(at: datePath)?.boolValue ?? dateDefault
        )
    }
}

extension CmuxConfigSnapshot {
    /// `tabs.newTabClock.*`; nil when the clock is off.
    public var newTabClock: NewTabClockSetting? { NewTabClockSetting.clock(in: root) }
}
