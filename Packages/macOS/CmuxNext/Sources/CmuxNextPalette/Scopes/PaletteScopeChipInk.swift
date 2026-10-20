import AppKit
import CmuxNextDesign

/// The colors of one scope chip at the start of the search field: the text and icon tone, and the
/// fill behind them. One value for the view and the contrast test, so they cannot drift.
struct PaletteScopeChipInk: Equatable {
    /// What is behind the chip's text.
    enum Fill: Equatable {
        /// No fill: the panel shows through.
        case none
        /// The selected-row fill.
        case selection
        /// The selected-row fill at half strength.
        case halfSelection
    }

    /// The text color.
    var text: PaletteTone
    /// The icon color.
    var icon: PaletteTone
    /// The fill behind the text.
    var fill: Fill
    /// Whether a hairline outlines the chip.
    var outlined: Bool

    /// The chip on top of the stack (the scope you are in), or one under it (a click goes back).
    /// - Parameters:
    ///   - isTop: The chip of the current scope.
    ///   - increaseContrast: The macOS Increase Contrast setting.
    static func ink(isTop: Bool, increaseContrast: Bool) -> PaletteScopeChipInk {
        isTop ? PaletteScopeChipInk(text: .primary, icon: .secondary, fill: .selection, outlined: false)
            : PaletteScopeChipInk(text: .tertiary, icon: .tertiary, fill: .halfSelection, outlined: false)
    }
}
