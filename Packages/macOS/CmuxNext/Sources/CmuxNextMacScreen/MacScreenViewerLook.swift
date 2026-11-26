import AppKit
public import CmuxNextDesign

/// How the screen-share viewer pane is drawn (Debug Settings `macScreen.viewerLook`, Leo 2026-11-21: "our screen shared
/// screen looks like ass"). `a` is the default; `current` is the pane before the redesign; `b` and `c` are the competing
/// redesigns, each in its own file (`MacScreenViewerLook+A.swift` and so on) that only fills in its ``MacScreenViewerStyle``.
public nonisolated enum MacScreenViewerLook: String, Sendable, CaseIterable, Hashable, TunableChoice {
    /// The pane before the redesign: a top toolbar bar, a black backdrop, a square picture, a popup card.
    case current
    /// The default: quiet glass, picture first (``MacScreenLookA``).
    case a
    case b
    case c

    public var tunableTitle: String {
        switch self {
        case .current: "Current: top toolbar, black backdrop"
        case .a: "Look A (default): quiet glass, picture first"
        case .b: "Look B"
        case .c: "Look C: floating pill, full-pane states"
        }
    }

    /// A look's fields never change while the app runs: Rust is asked once per look, not on every layout.
    @MainActor private static let rdStyles: [MacScreenViewerLook: [String: Any]] = Dictionary(
        uniqueKeysWithValues: allCases.map { ($0, RdUI.call("viewerLook.style", ["look": $0.rawValue]) as? [String: Any] ?? [:]) }
    )

    /// What this look decides. A look is one value: the pane, toolbar and card read it, nothing else branches on the case.
    /// Rust's `viewerLook.style` decides the fields; Swift adds the look's materials, which are views.
    @MainActor var style: MacScreenViewerStyle {
        var style = MacScreenViewerStyle(rd: Self.rdStyles[self] ?? [:])
        switch self {
        case .a: style.toolbarSurface = { MacScreenLookA.glass(cornerRadius: $0) }
        case .c: style.makeToolbarSurface = { MacScreenViewerLookC.pillSurface() }
        case .current, .b: break
        }
        return style
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
        /// The page fill other page tabs use (clear over the window's material).
        case page

        func color(_ colors: MacScreenColors) -> NSColor {
            switch self {
            case .black: .black
            case .chrome: colors.chrome
            case .page: colors.page
            }
        }
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
    /// The material behind the toolbar, made for its corner radius (nil: none, the toolbar's own fill).
    var toolbarSurface: (@MainActor (CGFloat) -> NSView)?
    /// The toolbar's row height (nil: fitted to its controls).
    var toolbarRowHeight: CGFloat?
    /// A View | Control segmented control in place of the access menu.
    var toolbarScopeSegments = false
    /// A floating toolbar fades out after a while live and idle, and back in at the pane's top edge.
    var toolbarAutoHide = false
    /// Marks on the live picture: a focus-color edge and a Controlling pill while the keyboard goes to the other Mac,
    /// a View Only pill in a View Only session, a quiet Reconnecting pill during an outage.
    var pictureMarks = false
    /// A stall with a picture up keeps the last frame and shows no card (an outage is not an error).
    var outageKeepsPicture = false
    /// Transient cards (connecting, waiting) are a small mark and one line, with no surface.
    var cardQuietTransient = false

    /// The pane as shipped.
    static var current: MacScreenViewerStyle { MacScreenViewerStyle() }

    /// The style Rust's `viewerLook.style` answers (its field names; a `Metrics` token or points for a length).
    init(rd: [String: Any]) {
        func points(_ value: Any?) -> CGFloat? {
            switch value {
            case let number as Double: CGFloat(number)
            case "space4" as String: Metrics.space4
            case "space5" as String: Metrics.space5
            case "surfaceCornerRadius" as String: Metrics.surfaceCornerRadius
            case let text as String: Double(text).map { CGFloat($0) }
            default: nil
            }
        }
        func flag(_ key: String) -> Bool { rd[key] as? Bool ?? false }
        toolbarPlacement = rd["toolbarPlacement"] as? String == "floating" ? .floating : .topBar
        toolbarFilled = rd["toolbarFilled"] as? Bool ?? true
        toolbarCornerRadius = points(rd["toolbarCornerRadius"]) ?? 0
        toolbarInset = points(rd["toolbarInset"]) ?? 0
        backdrop = switch rd["backdrop"] as? String { case "page": .page; case "chrome": .chrome; default: .black }
        pictureCornerRadius = points(rd["pictureCornerRadius"]) ?? 0
        pictureShadow = flag("pictureShadow")
        cardCornerRadius = points(rd["cardCornerRadius"])
        cardFill = rd["cardFill"] as? String == "page" ? \.page : \.popup
        cardBordered = rd["cardBordered"] as? Bool ?? true
        statusStrip = flag("statusStrip")
        toolbarLayout = rd["toolbarLayout"] as? String == "pill" ? .pill : .bar
        cardLayout = rd["cardLayout"] as? String == "fullPane" ? .fullPane : .standard
        cardWidth = points(rd["cardWidth"])
        cardVeilOpacity = points(rd["cardVeilOpacity"]) ?? 0
        quietOutage = flag("quietOutage")
        toolbarRowHeight = points(rd["toolbarRowHeight"])
        toolbarScopeSegments = flag("toolbarScopeSegments")
        toolbarAutoHide = flag("toolbarAutoHide")
        pictureMarks = flag("pictureMarks")
        outageKeepsPicture = flag("outageKeepsPicture")
        cardQuietTransient = flag("cardQuietTransient")
    }
}

extension MacScreenPaneModel {
    /// A stall over a shown picture that the look keeps quiet (``MacScreenViewerStyle/quietOutage``): the picture
    /// stays, the card does not show, input still waits for the picture to come back.
    var isQuietOutage: Bool {
        RdUI.call("viewerLook.isQuietOutage", rdState()) as? Bool ?? false
    }
}
