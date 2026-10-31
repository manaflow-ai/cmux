import Foundation
public import CmuxNextDesignTokens

/// One customizable appearance property (plans/cmux-next/appearance-scopes-DESIGN.md), with the
/// levels where it means something and the values it takes.
public nonisolated enum AppearanceProperty: String, CaseIterable, Sendable {
    /// A Ghostty theme name or a `light:A,dark:B` pair.
    case theme
    /// A background image: `appearance.background`'s vocabulary.
    case background
    /// A marker color washed over the place: a named color or `#RRGGBB`.
    case tint
    /// The glass tint over a background image, 0...1 (1 is opaque and hides it).
    case opacity
    /// The window material: one per window.
    case blur
    /// Terminal font size in points, 6...72.
    case fontSize
    /// Terminal cursor shape.
    case cursorStyle

    /// The levels a person (or agent) may set this property at.
    public var levels: Set<AppearanceLevel> {
        switch self {
        case .theme: Set(AppearanceLevel.allCases)
        case .background: [.app, .window, .workspace, .rule, .pane]
        case .tint: [.window, .workspace, .rule, .pane, .tab]
        case .opacity: [.app, .window, .workspace, .pane]
        case .blur: [.app, .window]
        case .fontSize, .cursorStyle: [.app, .workspace, .rule, .pane, .tab]
        }
    }

    /// The cursor shapes Ghostty draws (`cursor-style`).
    public static let cursorStyles = ["block", "bar", "underline", "block_hollow"]
    /// The materials `appearance.backgroundBlur` takes.
    public static let materials = ["frosted", "glass", "glassClear", "none"]

    /// Whether `value` is a value of this property (`reset` removes a value; it is never one).
    public func accepts(_ value: String) -> Bool {
        switch self {
        case .theme:
            !value.trimmingCharacters(in: .whitespaces).isEmpty && !value.contains(where: \.isNewline)
        case .background:
            value == "none" || value == "daily" || BackdropSelection(id: value) != nil
        case .tint:
            PaneTint(value) != nil
        case .opacity:
            Double(value).map { $0.isFinite && (0...WindowBackdrop.maximumWorkspaceTint).contains($0) } ?? false
        case .blur:
            Self.materials.contains(value)
        case .fontSize:
            Double(value).map { $0.isFinite && (6...72).contains($0) } ?? false
        case .cursorStyle:
            Self.cursorStyles.contains(value)
        }
    }
}
