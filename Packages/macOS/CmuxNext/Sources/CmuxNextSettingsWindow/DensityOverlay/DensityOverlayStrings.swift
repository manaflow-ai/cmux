import Foundation

/// Text of the Density Overlay Playground (Localizable.xcstrings in this module).
nonisolated struct DensityOverlayStrings {
    static var title: String { text("densityOverlay.title", "Density Overlay Playground") }
    static var reference: String { text("densityOverlay.reference", "Reference") }
    static var chooseReference: String { text("densityOverlay.chooseReference", "Choose Image…") }
    static var noReference: String { text("densityOverlay.noReference", "Choose a reference image of Helium's or Chrome's tab bar and omnibar.") }
    static var noBrowserPane: String { text("densityOverlay.noBrowserPane", "Open a browser pane with its omnibar showing in a cmux window.") }
    static var capture: String { text("densityOverlay.capture", "Capture") }
    static var live: String { text("densityOverlay.live", "Live") }
    static var controls: String { text("densityOverlay.controls", "Controls…") }
    static var overlay: String { text("densityOverlay.mode.overlay", "Overlay") }
    static var difference: String { text("densityOverlay.mode.difference", "Difference") }
    static var flip: String { text("densityOverlay.mode.flip", "Flip") }
    static var sideBySide: String { text("densityOverlay.mode.sideBySide", "Side by Side") }
    static var opacity: String { text("densityOverlay.opacity", "Opacity") }
    static var zoom: String { text("densityOverlay.zoom", "Zoom") }
    static var threshold: String { text("densityOverlay.threshold", "Tolerance") }
    static func offset(_ x: Int, _ y: Int) -> String {
        String(format: text("densityOverlay.offset", "Offset %lld, %lld px"), locale: Locale.current, x, y)
    }
    static func differing(_ count: Int, of total: Int, percent: String) -> String {
        String(format: text("densityOverlay.differing", "%1$lld of %2$lld pixels differ (%3$@)"), locale: Locale.current, count, total, percent)
    }
    static func differenceBounds(_ minX: Int, _ maxX: Int, _ minY: Int, _ maxY: Int) -> String {
        String(format: text("densityOverlay.differenceBounds", "Differences from x %1$lld to %2$lld, y %3$lld to %4$lld px"),
               locale: Locale.current, minX, maxX, minY, maxY)
    }
    static var matches: String { text("densityOverlay.matches", "No pixel differs.") }

    static func mode(_ mode: DensityOverlayModel.Mode) -> String {
        switch mode {
        case .overlay: overlay
        case .difference: difference
        case .flip: flip
        case .sideBySide: sideBySide
        }
    }

    private static func text(_ key: StaticString, _ value: String.LocalizationValue) -> String {
        String(localized: key, defaultValue: value, bundle: .module)
    }
}
