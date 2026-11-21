import AppKit
public import CmuxNextDesign

/// How the screen-share viewer pane is drawn (Debug Settings `macScreen.viewerLook`, Leo 2026-11-21: "our screen shared
/// screen looks like ass"). `current` is today's pane; `a`, `b` and `c` are slots for competing redesigns, each in its own
/// file (`MacScreenViewerLook+A.swift` and so on) that only fills in its ``MacScreenViewerStyle``. They draw as `current`
/// until a look sets its fields.
public nonisolated enum MacScreenViewerLook: String, Sendable, CaseIterable, Hashable, TunableChoice {
    /// The pane as shipped: a top toolbar bar, a black backdrop, a square picture, a popup card.
    case current
    case a
    case b
    case c

    public var tunableTitle: String {
        switch self {
        case .current: "Current (default): top toolbar, black backdrop"
        case .a: "Look A"
        case .b: "Look B"
        case .c: "Look C"
        }
    }

    /// What this look decides. A look is one value: the pane, toolbar and card read it, nothing else branches on the case.
    @MainActor var style: MacScreenViewerStyle {
        switch self {
        case .current: .current
        case .a: .lookA
        case .b: .lookB
        case .c: .lookC
        }
    }
}

/// Everything a viewer look can change, read by `MacScreenPaneView` (placement, backdrop, picture), `MacScreenToolbarView`
/// (material) and `MacScreenCardView` (card style). A look file sets fields on `.current`'s defaults:
///
///     extension MacScreenViewerStyle {
///         static var lookA: MacScreenViewerStyle {
///             var style = MacScreenViewerStyle.current
///             style.toolbarPlacement = .floating
///             return style
///         }
///     }
///
/// New fields belong here with the default that keeps `current` unchanged; the layout code that reads them is the only other edit.
@MainActor
struct MacScreenViewerStyle {
    enum ToolbarPlacement {
        /// A bar on top; the picture fits in the area below it.
        case topBar
        /// A capsule over the top of the picture; the picture fits the whole pane. Auto-hide is a look's own addition.
        case floating
    }

    enum Backdrop {
        /// Black around the letterboxed picture.
        case black
        /// The theme's chrome color.
        case chrome
    }

    var toolbarPlacement = ToolbarPlacement.topBar
    /// Whether the toolbar paints the theme's chrome fill (false: clear, for a look that draws its own material).
    var toolbarFilled = true
    var toolbarCornerRadius: CGFloat = 0
    /// The gap from the pane's edges to a floating toolbar.
    var toolbarInset: CGFloat = 0
    var backdrop = Backdrop.black
    var pictureCornerRadius: CGFloat = 0
    /// A soft shadow under the picture, where it meets the backdrop.
    var pictureShadow = false
    /// The state card's corner radius (nil: the design system's panel radius).
    var cardCornerRadius: CGFloat?
    var cardFill: KeyPath<MacScreenColors, NSColor> = \.popup
    var cardBordered = true

    /// The pane as shipped.
    static var current: MacScreenViewerStyle { MacScreenViewerStyle() }
}
