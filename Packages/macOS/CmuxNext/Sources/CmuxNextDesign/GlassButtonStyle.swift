public import AppKit
public import SwiftUI
import CmuxNextWakeups
public import CmuxTheme

extension View {
    /// The Liquid Glass button style (`.glass`, macOS 26 and later), or
    /// `.bordered` where Liquid Glass is missing
    /// (`Glass.isLiquidGlassAvailable`). It shows the arrow, as native buttons do.
    @ViewBuilder
    public func glassButtonStyle() -> some View {
        if #available(macOS 26.0, *), Glass.isLiquidGlassAvailable {
            buttonStyle(.glass)
        } else {
            buttonStyle(.bordered)
        }
    }
}

// The pressed look lives beside the glass style: macOS adds no new SwiftUI files (check-no-swiftui.py).
/// The one pressed look for a SwiftUI button in cmux NEXT: while it is held the label stays exactly as it is
/// (no bold, no other font or size, no scale, no dimming) and only the fill behind it changes (DESIGN.md
/// "Pressed state", Lawrence 2026-11-15: "we only want to have different bg color on mousedown").
///
/// SwiftUI's own `.plain`, `.borderless` and `.link` styles dim the label while it is held, so cmux uses this
/// style instead; `scripts/cmux-next/check-pressed-state.py` refuses them. AppKit chrome gets the same look from
/// ``ChromeHover`` (`ChromeHover.State(pressed:)` picks `Palette.pressedFill`).
///
/// On a menu panel's glass (``Glass/makeMenuPanel(content:cornerRadius:interactive:)``) a label that takes its ink from
/// the button draws the theme's text fit to that glass (``GlassMenuMaterial/ink(_:tokens:minimum:)``), not the ink fit to
/// the opaque page: Hot Dog Stand's Rename read 4.16:1 over a black page. In a ``ThemedHostingView`` the button has the
/// glass before its first draw; in any other host it finds the panel in the view tree (``MenuGlassProbeView``) and
/// takes it after the frame commit, so content a menu panel hosts sets no mark. A label that sets its own ink keeps it.
public struct CmuxPressFillButtonStyle: ButtonStyle {
    /// The fill at rest (and under the pointer); nil draws none.
    public var rest: Color?
    /// The fill while held; nil is `Palette.pressedFill`.
    public var pressed: Color?
    /// The fill's corner; nil is `Metrics.buttonCornerRadius`.
    public var cornerRadius: CGFloat?
    /// The fill's shape: the label's own shape, so a circle or capsule never shows a square wash.
    public var shape: CmuxPressShape

    public init(rest: Color? = nil, pressed: Color? = nil, cornerRadius: CGFloat? = nil, shape: CmuxPressShape = .rounded) {
        self.rest = rest
        self.pressed = pressed
        self.cornerRadius = cornerRadius
        self.shape = shape
    }

    public func makeBody(configuration: Configuration) -> some View {
        PressFillBody(configuration: configuration, style: self)
    }
}

/// ``CmuxPressFillButtonStyle``'s button: the label on its fill, in the menu glass ink while it sits on a menu panel.
private struct PressFillBody: View {
    let configuration: ButtonStyleConfiguration
    let style: CmuxPressFillButtonStyle
    /// The theme of the menu panel's glass the button sits on, read from the view tree; nil off menu glass.
    @State private var menuGlass: ThemeTokens?
    /// The same, given before the first draw by the ``ThemedHostingView`` the button is in.
    @Environment(\.cmuxMenuGlass) private var hostedMenuGlass

    var body: some View {
        shaped.background(MenuGlassProbe(menuGlass: $menuGlass))
    }

    @ViewBuilder
    private var shaped: some View {
        let label = configuration.label.modifier(MenuGlassInk(tokens: hostedMenuGlass ?? menuGlass))
        let fill = configuration.isPressed ? (style.pressed ?? Color(nsColor: Palette.pressedFill)) : style.rest
        switch style.shape {
        case .rounded:
            label.cmuxPressFill(configuration.isPressed, rest: style.rest, pressed: style.pressed, cornerRadius: style.cornerRadius)
        case .circle:
            label.background(fill ?? Color.clear, in: Circle()).contentShape(Circle())
        case .capsule:
            label.background(fill ?? Color.clear, in: Capsule()).contentShape(Capsule())
        case .glass:
            // Interactive Liquid Glass answers the press itself; only the rest fill is drawn.
            label.background(style.rest ?? Color.clear, in: Circle())
        }
    }
}

/// Hosts a ``MenuGlassProbeView`` behind the button and keeps `menuGlass` to what it finds.
private struct MenuGlassProbe: NSViewRepresentable {
    let menuGlass: Binding<ThemeTokens?>

    func makeNSView(context: Context) -> MenuGlassProbeView {
        let probe = MenuGlassProbeView(frame: .zero)
        updateNSView(probe, context: context)
        return probe
    }

    func updateNSView(_ probe: MenuGlassProbeView, context: Context) {
        let menuGlass = menuGlass
        // The probe reports from AppKit's view-tree callbacks, which can run inside SwiftUI's own update (a probe made
        // in a window moves to it there): the state is written once that pass committed its frame, never during it.
        probe.onChange = { tokens in AfterFrameCommit().run { menuGlass.wrappedValue = tokens } }
    }
}

/// The theme's text fit to the menu glass of `tokens` as the ink a label inherits; no change off menu glass.
private struct MenuGlassInk: ViewModifier {
    let tokens: ThemeTokens?

    func body(content: Content) -> some View {
        if let tokens {
            content.foregroundStyle(GlassMenuMaterial.ink(\.textPrimary, tokens: tokens).swiftUIColor)
        } else {
            content
        }
    }
}

/// The shape of ``CmuxPressFillButtonStyle``'s fill. A button whose label is a circle, a capsule or a glass disc
/// names it here; `scripts/cmux-next/check-pressed-state.py` refuses the default `.rounded` on those labels.
public enum CmuxPressShape: Sendable {
    /// A continuous rounded rectangle with the style's corner (the default).
    case rounded
    case circle
    case capsule
    /// No wash: the label is interactive Liquid Glass, whose own press response is the pressed look.
    case glass
}

extension ButtonStyle where Self == CmuxPressFillButtonStyle {
    /// ``CmuxPressFillButtonStyle`` with no fill at rest and `Palette.pressedFill` while held.
    public static var cmuxPressFill: CmuxPressFillButtonStyle { CmuxPressFillButtonStyle() }
    /// ``cmuxPressFill`` for a circular label.
    public static var cmuxPressFillCircle: CmuxPressFillButtonStyle { CmuxPressFillButtonStyle(shape: .circle) }
    /// ``cmuxPressFill`` for a capsule label.
    public static var cmuxPressFillCapsule: CmuxPressFillButtonStyle { CmuxPressFillButtonStyle(shape: .capsule) }
    /// For an interactive Liquid Glass label: no wash, the label unchanged.
    public static var cmuxPressGlass: CmuxPressFillButtonStyle { CmuxPressFillButtonStyle(shape: .glass) }
}

extension View {
    /// The pressed look of ``CmuxPressFillButtonStyle`` for a style that sets its own font, ink and padding
    /// first: the fill behind the label is `pressed` while `isPressed`, else `rest`; nothing else changes.
    public func cmuxPressFill(_ isPressed: Bool, rest: Color? = nil, pressed: Color? = nil, cornerRadius: CGFloat? = nil) -> some View {
        let fill = isPressed ? (pressed ?? Color(nsColor: Palette.pressedFill)) : rest
        return background(fill ?? Color.clear,
                          in: RoundedRectangle(cornerRadius: cornerRadius ?? Metrics.buttonCornerRadius, style: .continuous))
            .contentShape(Rectangle())
    }
}

extension EnvironmentValues {
    /// The theme of the menu panel's glass a ``ThemedHostingView`` sits on, nil off menu glass.
    @Entry var cmuxMenuGlass: ThemeTokens? = .none
    /// The inks of the ``ThemedHostingView`` the view is in, nil outside one. Nonisolated: ``ThemedInkStyle`` reads it
    /// where SwiftUI resolves a shape style, off the main actor.
    nonisolated var cmuxInks: ThemedInks? {
        get { self[ThemedInksKey.self] }
        set { self[ThemedInksKey.self] = newValue }
    }
}

/// The environment key of ``EnvironmentValues/cmuxInks``.
private nonisolated struct ThemedInksKey: EnvironmentKey {
    static let defaultValue: ThemedInks? = .none
}

/// The theme's secondary or tertiary text fit to the ground the view's ``ThemedHostingView`` sits on.
///
/// SwiftUI's own `.secondary` and `.tertiary` are the primary ink at a lower opacity, not the theme's secondary text:
/// in a ``ThemedHostingView`` on Rose Pine Dawn's menu glass over a black page `.secondary` read 2.00:1
/// (NativeControlContrastAuditTests). Outside a ``ThemedHostingView`` it is SwiftUI's own level.
///
/// ```swift
/// Text(BookmarkStrings.folder).foregroundStyle(.cmuxSecondary)
/// ```
public nonisolated struct ThemedInkStyle: ShapeStyle {
    /// Which ink: the secondary or the tertiary text.
    public enum Level: Sendable {
        /// The theme's secondary text.
        case secondary
        /// The theme's tertiary text.
        case tertiary
    }

    /// The ink this style draws.
    public let level: Level

    /// The host's fitted ink for ``level``, else SwiftUI's own hierarchical level.
    public func resolve(in environment: EnvironmentValues) -> AnyShapeStyle {
        guard let inks = environment.cmuxInks else {
            return AnyShapeStyle(level == .secondary ? HierarchicalShapeStyle.secondary : .tertiary)
        }
        return AnyShapeStyle((level == .secondary ? inks.secondary : inks.tertiary).swiftUIColor)
    }
}

nonisolated extension ShapeStyle where Self == ThemedInkStyle {
    /// The theme's secondary text fit to the ground of the ``ThemedHostingView`` the view is in.
    public static var cmuxSecondary: ThemedInkStyle { ThemedInkStyle(level: .secondary) }
    /// The theme's tertiary text fit to the ground of the ``ThemedHostingView`` the view is in.
    public static var cmuxTertiary: ThemedInkStyle { ThemedInkStyle(level: .tertiary) }
}

/// The theme's text inks a ``ThemedHostingView`` gives its content, each fit to the ground the view sits on.
public nonisolated struct ThemedInks: Equatable, Sendable {
    /// The primary ink: the theme's text, fit to the ground.
    public var primary: ThemeRGB
    /// The secondary ink: the theme's secondary text, fit to the ground.
    public var secondary: ThemeRGB
    /// The tertiary ink: the theme's tertiary text, fit to the ground.
    public var tertiary: ThemeRGB
    /// The theme of the menu panel's glass the host sits on; nil off menu glass.
    public var menuGlass: ThemeTokens?
}

/// A ``ThemedHostingView``'s root: its content in the host's primary ink as the foreground, and the inks and the menu
/// glass it sits on in the environment (``ThemedInkStyle``).
public struct ThemedInkRoot<Content: View>: View {
    /// The hosted view.
    public let content: Content
    /// The inks for the ground the host sits on; nil keeps SwiftUI's own.
    public let inks: ThemedInks?

    public var body: some View {
        // One shape whether or not the inks are known, so the content keeps its identity and state when they arrive.
        content
            .foregroundStyle(style(inks?.primary, .primary), style(inks?.secondary, .secondary), style(inks?.tertiary, .tertiary))
            .environment(\.cmuxMenuGlass, inks?.menuGlass)
            .environment(\.cmuxInks, inks)
    }

    private func style(_ ink: ThemeRGB?, _ fallback: HierarchicalShapeStyle) -> AnyShapeStyle {
        ink.map { AnyShapeStyle($0.swiftUIColor) } ?? AnyShapeStyle(fallback)
    }
}

/// The hosting view for SwiftUI content on a cmux surface. Its content draws the theme's text inks fit to the ground it
/// sits on, as each AppKit control fits its own (``NSView/buttonGround(_:)``): on a menu panel's glass
/// (``Glass/makeMenuPanel(content:cornerRadius:interactive:)``) the glass over the theme's window, a white and a black
/// page; on a window its surface, over the worst desktop when it is see-through. Text, a toggle's label and a button's
/// label that set no ink of their own take the primary, `.cmuxSecondary` and `.cmuxTertiary` are the others
/// (``ThemedInkStyle``; SwiftUI's `.secondary` is the primary at a lower opacity), and a ``CmuxPressFillButtonStyle``
/// button knows the menu glass. The host reads its ground from the view tree as it moves
/// and as its theme or appearance changes, and hands it to its content at once: before the first draw, never a frame
/// late. Chief 2026-11-23: every SwiftUI control on menu glass, not only the press-fill button. A plain
/// `NSHostingView` on a menu panel is refused by check-overlay-glass.py (`menu-hosting`).
///
/// ```swift
/// let content = ThemedHostingView(rootView: BookmarkEditView(model: model))
/// let card = Glass.makeMenuPanel(content: content)
/// ```
open class ThemedHostingView<Content: View>: NSHostingView<ThemedInkRoot<Content>> {
    /// The hosted view; setting it keeps the inks.
    public var content: Content {
        didSet { rootView = ThemedInkRoot(content: content, inks: inks) }
    }
    /// The inks the content draws in now.
    public private(set) var inks: ThemedInks?
    /// A click on a control acts on the first click, also while the window is not key (a popup opened without the keys).
    public var actsOnFirstClick: Bool

    /// Hosts `content` in the theme's inks fit to where this view sits.
    /// - Parameters:
    ///   - content: The SwiftUI view to host.
    ///   - actsOnFirstClick: Whether a click acts while the window is not key (default false, as `NSHostingView`).
    public init(rootView content: Content, actsOnFirstClick: Bool = false) {
        self.content = content
        self.actsOnFirstClick = actsOnFirstClick
        super.init(rootView: ThemedInkRoot(content: content, inks: nil))
        refreshInks()
    }

    @available(*, unavailable)
    public required init(rootView: ThemedInkRoot<Content>) { fatalError("init(rootView:) takes the content, not its root") }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // A main-actor generic class's isolated deinit crashes the Release compile (swift-frontend 6.3, macOS 14 target).
    nonisolated deinit {}

    open override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        refreshInks()
    }

    open override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        refreshInks()
    }

    // A theme change repaints each view it draws through this hook (ThemeRepaint), as an appearance change does.
    open override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshInks()
    }

    open override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        actsOnFirstClick || super.acceptsFirstMouse(for: event)
    }

    /// Reads the ground from the view tree and gives the content its inks when they changed.
    private func refreshInks() {
        let next = performWithTheme {
            let tokens = ThemeContext.active ?? ThemeScope.app.tokens
            let ground = buttonGround(tokens)
            func fit(_ ink: KeyPath<ThemeTokens, ThemeRGB>) -> ThemeRGB {
                CmuxDialogButtonLook.readable(tokens[keyPath: ink].composited(over: ground[0]), over: ground)
            }
            return ThemedInks(primary: fit(\.textPrimary), secondary: fit(\.textSecondary), tertiary: fit(\.textTertiary),
                              menuGlass: enclosingOverlaySurface?.tintLevel == GlassMenuMaterial.level ? tokens : nil)
        }
        guard next != inks else { return }
        inks = next
        rootView = ThemedInkRoot(content: content, inks: next)
    }
}
