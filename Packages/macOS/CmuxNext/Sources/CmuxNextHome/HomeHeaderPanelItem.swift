public import AppKit
import CmuxNextDesign

/// One toggle of the Home transcript header's top-right cluster (Claude desktop's panel buttons):
/// a panel beside Home that the button opens and, clicked again, closes. The host says what each
/// one is and whether its panel is open; the bar only draws and reports clicks.
public struct HomeHeaderPanelItem: Equatable, Sendable {
    /// Stable id, also the button's accessibility identifier suffix (`cmux.home.headerPanel.<id>`).
    public var id: String
    /// SF Symbol while closed, and while open (drawn in the theme's accent).
    public var symbol: String
    public var onSymbol: String
    /// The localized name: the button's VoiceOver label and its tooltip.
    public var label: String
    /// The toggle's keyboard shortcut for the tooltip ("⌥⌘B"); nil for none.
    public var shortcut: String?
    /// The panel is open: the button shows on.
    public var isOn: Bool

    public init(id: String, symbol: String, onSymbol: String? = nil, label: String, shortcut: String? = nil, isOn: Bool) {
        self.id = id
        self.symbol = symbol
        self.onSymbol = onSymbol ?? symbol
        self.label = label
        self.shortcut = shortcut
        self.isOn = isOn
    }
}
