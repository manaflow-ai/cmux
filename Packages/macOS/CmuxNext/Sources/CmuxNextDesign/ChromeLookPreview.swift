import Foundation

/// A preview-only look for the tab bar's trailing controls and the sidebar's titlebar +, picked by
/// the `-cmuxChromeLook NAME` launch argument (Lawrence 2026-10-30, msg 18472: "i like how it looked
/// in original cmux"). Scratch for the variant gallery; never landed as is. Nil without the argument.
nonisolated public struct ChromeLookPreview: Sendable {
    /// Draw the strip's + after the last tab.
    public var stripPlus: Bool
    /// Draw the separate ⌄ chooser beside the strip's +.
    public var stripChevron: Bool
    /// Draw the ⌄ inside the + (one "+⌄" control).
    public var stripPlusChevron: Bool
    /// The trailing buttons, catalog action ids, in order.
    public var toolbar: [String]
    /// Draw the trailing ⋮.
    public var more: Bool
    /// Draw the sidebar titlebar's ⌄ beside its +.
    public var sidebarChevron: Bool

    /// The look this launch asked for, if any.
    public static let current: ChromeLookPreview? = UserDefaults.standard.string(forKey: "cmuxChromeLook").flatMap(named)

    /// cmux classic's symbols for the trailing buttons (bonsplit `SplitActionButton.defaults`).
    public static let classicSymbols: [String: String] = [
        "newSurface": "terminal", "openBrowser": "globe",
        "splitRight": "square.split.2x1", "splitDown": "square.split.1x2",
    ]

    static func named(_ name: String) -> ChromeLookPreview? {
        let classic = ["newSurface", "openBrowser", "splitRight", "splitDown"]
        switch name {
        case "current": return .init(stripPlus: true, stripChevron: true, stripPlusChevron: false, toolbar: [], more: true, sidebarChevron: true)
        case "classic": return .init(stripPlus: false, stripChevron: false, stripPlusChevron: false, toolbar: classic, more: false, sidebarChevron: false)
        case "classic-more": return .init(stripPlus: false, stripChevron: false, stripPlusChevron: false, toolbar: classic, more: true, sidebarChevron: false)
        case "classic-plus": return .init(stripPlus: true, stripChevron: false, stripPlusChevron: false, toolbar: ["splitRight", "splitDown"], more: false, sidebarChevron: false)
        case "plus-only": return .init(stripPlus: true, stripChevron: false, stripPlusChevron: false, toolbar: [], more: false, sidebarChevron: false)
        case "plus-more": return .init(stripPlus: true, stripChevron: false, stripPlusChevron: false, toolbar: [], more: true, sidebarChevron: false)
        case "plus-splits-more": return .init(stripPlus: true, stripChevron: false, stripPlusChevron: false, toolbar: ["splitRight", "splitDown"], more: true, sidebarChevron: false)
        case "plus-joined-chevron": return .init(stripPlus: true, stripChevron: false, stripPlusChevron: true, toolbar: [], more: true, sidebarChevron: true)
        case "terminal-globe-more": return .init(stripPlus: false, stripChevron: false, stripPlusChevron: false, toolbar: ["newSurface", "openBrowser"], more: true, sidebarChevron: false)
        case "splits-more": return .init(stripPlus: false, stripChevron: false, stripPlusChevron: false, toolbar: ["splitRight", "splitDown"], more: true, sidebarChevron: false)
        default: return nil
        }
    }
}
