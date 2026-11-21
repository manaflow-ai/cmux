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
        case .c: "Look C: floating pill, full-pane states"
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
        /// The pane's page fill (the window material, as on other page tabs): the picture letterboxes on the window's ground.
        case page
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
    /// The toolbar and the state card give way to a fixed status strip on top (``MacScreenStatusStrip``): it carries the
    /// state and its buttons, and the screen area below holds only the picture or a calm mark.
    var statusStrip = false

    enum ToolbarLayout {
        /// Every control in the bar (stacked, then folded into More, as the pane narrows).
        case bar
        /// A one-row pill: name, latency, access, quality and Disconnect; the rest in More. Shown only while live.
        case pill
    }

    enum CardLayout {
        /// The card as shipped: a fixed-width popup with a spinner or a glyph, a title and buttons.
        case standard
        /// A large, calm state that reads as the whole pane: a big symbol, a headline, one line of why,
        /// named connect steps, a primary and a secondary button, the details faint.
        case fullPane
    }

    var toolbarLayout = ToolbarLayout.bar
    /// The material behind the toolbar's controls, made once per look (nil: none, the fill above decides).
    var makeToolbarSurface: (@MainActor () -> NSView)?
    var cardLayout = CardLayout.standard
    /// The card's width (nil: ``MacScreenCardView/width``).
    var cardWidth: CGFloat?
    /// While a card shows over a picture (a stall, a reconnect), the picture is dimmed under a veil of the
    /// backdrop at this opacity (0: the card sits over the picture as is).
    var cardVeilOpacity: CGFloat = 0
    /// A brief outage over a shown picture (a stall) keeps the last frame up with no card over it; the toolbar says
    /// Reconnecting quietly instead (false: the Reconnecting card covers the picture).
    var quietOutage = false

    /// The pane as shipped.
    static var current: MacScreenViewerStyle { MacScreenViewerStyle() }

    /// The pane's color around the letterboxed picture, in `colors` (the toolbar's resolved colors).
    func backdropColor(_ colors: MacScreenColors) -> NSColor {
        switch backdrop {
        case .black: .black
        case .chrome: colors.chrome
        case .page: colors.page
        }
    }
}

extension MacScreenPaneModel {
    /// A stall over a shown picture that the look keeps quiet (``MacScreenViewerStyle/quietOutage``): the picture
    /// stays, the card does not show, input still waits for the picture to come back.
    var isQuietOutage: Bool {
        guard viewerLook.style.quietOutage, isLive, hasFrame, case .connecting(reconnecting: true)? = card else { return false }
        return true
    }
}
