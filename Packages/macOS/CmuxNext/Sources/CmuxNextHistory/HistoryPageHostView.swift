public import AppKit
import CmuxNextDesign
import SwiftUI

/// Hosts the history page in a browser tab's content area. Resolves the
/// page colors in this view's theme scope (room, workspace) and again on
/// every theme change.
public final class HistoryPageHostView: NSView {
    public let model: HistoryPageModel
    private let appearanceState = HistoryPageAppearance()
    private var hosting: NSHostingView<HistoryPageView>?

    public init(model: HistoryPageModel) {
        self.model = model
        super.init(frame: .zero)
        wantsLayer = true
        let hosting = NSHostingView(rootView: HistoryPageView(model: model, appearance: appearanceState))
        hosting.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: trailingAnchor),
            hosting.topAnchor.constraint(equalTo: topAnchor),
            hosting.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        self.hosting = hosting
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    nonisolated public override var wantsUpdateLayer: Bool { true }

    public override func updateLayer() {
        resolveColors()
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        resolveColors()
    }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        resolveColors()
    }

    private func resolveColors() {
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
