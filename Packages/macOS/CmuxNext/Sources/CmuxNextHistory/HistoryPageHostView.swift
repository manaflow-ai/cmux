public import AppKit
public import CmuxNextDesign
import CmuxNextWakeups
import SwiftUI

/// Hosts the history page in a browser tab's content area. Resolves the
/// page colors in this view's theme scope (room, workspace) and again on
/// every theme change (once, on show, for a hidden page).
public final class HistoryPageHostView: NSView, VisibilityGatedContent {
    public let model: HistoryPageModel
    private let appearanceState: HistoryPageAppearance
    private let gate: VisibilityGatedHostingView
    /// The view's place in the visibility tree: a theme change while the page is hidden resolves the colors once, on show.
    private let visibility = ViewVisibility("history")
    private var visibilityNode: VisibilityNode { visibility.node }
    /// How many times the colors were resolved (tests: a hidden page resolves none until it shows).
    private(set) var colorResolves = 0

    /// Its SwiftUI leaves the hierarchy while the tab is hidden (``VisibilityGatedHostingView``).
    public var visibilityGate: VisibilityGatedHostingView? { gate }

    public init(model: HistoryPageModel) {
        let appearance = HistoryPageAppearance()
        self.model = model
        appearanceState = appearance
        gate = VisibilityGatedHostingView(owner: "HistoryPageHostView",
                                          hosting: NSHostingView(rootView: HistoryPageView(model: model, appearance: appearance)))
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        gate.translatesAutoresizingMaskIntoConstraints = false
        addSubview(gate)
        NSLayoutConstraint.activate([
            gate.leadingAnchor.constraint(equalTo: leadingAnchor),
            gate.trailingAnchor.constraint(equalTo: trailingAnchor),
            gate.topAnchor.constraint(equalTo: topAnchor),
            gate.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    nonisolated public override var wantsUpdateLayer: Bool { true }

    public override func updateLayer() {
        resolveColors()
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        visibility.place(in: window)
        resolveColors()
    }

    // R-hide: hiding forwards to the node.
    public override func viewDidHide() {
        super.viewDidHide()
        visibilityNode.set(.hidden)
    }

    public override func viewDidUnhide() {
        super.viewDidUnhide()
        visibilityNode.set(.visible)
    }

    // R-appear: the colors feed the SwiftUI page, so a hidden page resolves them on show.
    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        visibilityNode.deferUntilVisible(key: Self.appearanceKey) { [weak self] in self?.resolveColors() }
    }

    private static let appearanceKey = "HistoryPageHostView.appearance"

    private func resolveColors() {
        colorResolves += 1
        let colors = Self.colors(in: self)
        if appearanceState.colors != colors { appearanceState.colors = colors }
    }

    /// The page colors in `view`'s theme scope (the Stashed page resolves them the same way).
    static func colors(in view: NSView) -> HistoryPageColors {
        view.performWithTheme {
            let background = Palette.surfaceOverride(.internalPage) ?? Palette.paneFill
            view.layer?.backgroundColor = nil
            return HistoryPageColors(
                background: Color(nsColor: fixed(background)), primary: Color(nsColor: fixed(Palette.textPrimary)),
                secondary: Color(nsColor: fixed(Palette.textSecondary)), tertiary: Color(nsColor: fixed(Palette.textTertiary)),
                hover: Color(nsColor: fixed(Palette.hoverFill)), selection: Color(nsColor: fixed(Palette.selectionFill)),
                separator: Color(nsColor: fixed(Palette.separator)), danger: Color(nsColor: fixed(Palette.danger)))
        }
    }

    /// A static color: dynamic ones would re-resolve in SwiftUI's own
    /// appearance, outside this view's theme scope.
    private static func fixed(_ color: NSColor) -> NSColor {
        color.usingColorSpace(.sRGB) ?? color
    }
}
