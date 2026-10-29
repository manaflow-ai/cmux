public import AppKit
public import CmuxNextDesign
import SwiftUI

/// Hosts the Tasks pane in a tab's content area. The App creates it with a
/// model over `SocketTasksSource`; demos use `MockTasksSource`. The layout
/// comes from `layout`, read in a tracked scope: when it reads observable
/// state (the App passes the user setting `tasks.layout` from cmux.json),
/// a change switches the layout live. Resolves the
/// pane colors (chrome tokens and the terminal's ANSI palette) in this
/// view's theme scope in `updateLayer`: a theme change marks the view for
/// display (AppKit on an appearance change, `ThemeRepaint` on a scope
/// repaint), and AppKit does not display a hidden view, so a pane hidden
/// during any number of theme changes resolves them once, on show.
public final class TasksHostView: NSView, VisibilityGatedContent {
    public let model: TasksModel
    private let appearanceState: TasksAppearance
    private let gate: VisibilityGatedHostingView
    /// How many times the pane's colors were resolved (tests: a hidden pane resolves none until it shows).
    package private(set) var colorResolves = 0

    /// Its SwiftUI leaves the hierarchy while the tab is hidden (``VisibilityGatedHostingView``).
    public var visibilityGate: VisibilityGatedHostingView? { gate }

    /// The pane's tab title (localized).
    public static var paneTitle: String { TasksStrings.title }

    public init(model: TasksModel, layout: @escaping @MainActor () -> TasksLayout) {
        let appearance = TasksAppearance()
        self.model = model
        appearanceState = appearance
        // The pane counts its own bodies (TasksRoot, TasksView) into the gate's counter.
        let counter = HostingBodyCounter()
        let root = TasksRoot(model: model, appearance: appearance, layout: layout).environment(\.hostingBodyCounter, counter)
        gate = VisibilityGatedHostingView(owner: "TasksHostView", counter: counter, hosting: NSHostingView(rootView: root))
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

    /// A fixed layout (demos and snapshots).
    public convenience init(model: TasksModel, layout: TasksLayout) {
        self.init(model: model, layout: { layout })
    }

    nonisolated public override var wantsUpdateLayer: Bool { true }

    public override func updateLayer() {
        resolveColors()
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        resolveColors()
    }

    private func resolveColors() {
        colorResolves += 1
        let colors = performWithTheme {
            // The glyph knock-out color stays opaque; the page itself
            // paints the pane's fill (`Palette.paneFill`).
            let background = (Palette.surfaceOverride(.internalPage) ?? Palette.contentBackground).withAlphaComponent(1)
            layer?.backgroundColor = nil
            let tokens = themeTokens
            let ansi = tokens.ansi.map { rgb in
                Self.color(ThemeTokens.readable(rgb, over: tokens.contentBackground, minimum: ThemeTokens.minimumMarkContrast).nsColor)
            }
            return TasksColors(
                background: Self.color(background), surface: Self.color(Palette.surfaceOverride(.internalPage) ?? Palette.paneFill),
                surfaceIsOpaque: (Palette.surfaceOverride(.internalPage) ?? Palette.paneFill).alphaComponent >= 1, elevated: Self.color(Palette.elevatedBackground),
                primary: Self.color(Palette.textPrimary), secondary: Self.color(Palette.textSecondary),
                tertiary: Self.color(Palette.textTertiary), hover: Self.color(Palette.hoverFill),
                selection: Self.color(Palette.selectionFill), separator: Self.color(Palette.separator),
                attention: Self.color(Palette.attention), danger: Self.color(Palette.danger),
                success: Self.color(Palette.success), shadow: Self.color(Palette.shadow), ansi: ansi)
        }
        if appearanceState.colors != colors { appearanceState.colors = colors }
    }

    /// A static color: dynamic ones would re-resolve outside this view's theme scope.
    private static func color(_ color: NSColor) -> Color {
        Color(nsColor: color.usingColorSpace(.sRGB) ?? color)
    }
}

extension EnvironmentValues {
    /// The counter of the gated hosting view the Tasks pane is in (``VisibilityGatedHostingView``); nil elsewhere.
    @Entry var hostingBodyCounter: HostingBodyCounter?
}

/// Reads the layout and the resolved colors in a tracked scope, so a
/// settings or theme change updates the pane live.
struct TasksRoot: View {
    let model: TasksModel
    let appearance: TasksAppearance
    let layout: @MainActor () -> TasksLayout
    @Environment(\.hostingBodyCounter) private var bodyCounter

    var body: some View {
        bodyCounter?.record()
        return TasksView(model: model, layout: layout())
            .environment(\.tasksColors, appearance.colors)
    }
}
