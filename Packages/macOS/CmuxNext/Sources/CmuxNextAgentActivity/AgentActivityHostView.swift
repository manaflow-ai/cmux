public import AppKit
import CmuxNextDesign
import SwiftUI

/// Hosts the Agent activity pane in a tab's content area. The App creates
/// it with a model over the real CUA host source; demos use
/// `AgentActivityMockSource`. Resolves the pane colors in this view's theme
/// scope (room, workspace) and again on every theme change.
public final class AgentActivityHostView: NSView {
    public let model: AgentActivityModel
    private let appearanceState = AgentActivityAppearance()
    private var hosting: NSHostingView<AgentActivityRoot>?

    /// `layoutOverride` pins a prototype layout (demos and snapshots);
    /// nil follows the Debug Settings switch.
    public init(model: AgentActivityModel, layoutOverride: AgentActivityLayout? = nil) {
        self.model = model
        super.init(frame: .zero)
        wantsLayer = true
        let root = AgentActivityRoot(model: model, appearance: appearanceState, layoutOverride: layoutOverride)
        let hosting = NSHostingView(rootView: root)
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

    public override var wantsUpdateLayer: Bool { true }

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
        let colors = performWithTheme {
            let background = Palette.contentBackground
            layer?.backgroundColor = background.cgColor
            return AgentActivityColors(
                background: Self.color(background), sidebar: Self.color(Palette.sidebarBackground),
                elevated: Self.color(Palette.elevatedBackground), primary: Self.color(Palette.textPrimary),
                secondary: Self.color(Palette.textSecondary), tertiary: Self.color(Palette.textTertiary),
                hover: Self.color(Palette.hoverFill), selection: Self.color(Palette.selectionFill),
                badge: Self.color(Palette.badgeFill), separator: Self.color(Palette.separator),
                danger: Self.color(Palette.danger), success: Self.color(Palette.success),
                attention: Self.color(Palette.attention), shadow: Self.color(Palette.shadow))
        }
        if appearanceState.colors != colors { appearanceState.colors = colors }
    }

    /// A static color: dynamic ones would re-resolve in SwiftUI's own
    /// appearance, outside this view's theme scope.
    private static func color(_ color: NSColor) -> Color {
        Color(nsColor: color.usingColorSpace(.sRGB) ?? color)
    }
}

/// Reads the layout tunable and the resolved colors in a tracked scope, so a
/// Debug Settings or theme change updates the pane live.
struct AgentActivityRoot: View {
    let model: AgentActivityModel
    let appearance: AgentActivityAppearance
    var layoutOverride: AgentActivityLayout?

    var body: some View {
        AgentActivityView(model: model, layout: layoutOverride ?? AgentActivityTunables.layout.value)
            .environment(\.agentActivityColors, appearance.colors)
    }
}
