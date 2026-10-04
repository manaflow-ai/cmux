public import AppKit
import CmuxNextDesign
import SwiftUI

/// Hosts the Tasks pane in a tab's content area. The App creates it with a
/// model over `SocketTasksSource`; demos use `MockTasksSource`. The layout
/// comes from `layout`, read in a tracked scope: when it reads observable
/// state (the App passes the user setting `tasks.layout` from cmux.json),
/// a change switches the layout live. Resolves the
/// pane colors (chrome tokens and the terminal's ANSI palette) in this
/// view's theme scope and again on every theme change.
public final class TasksHostView: NSView {
    public let model: TasksModel
    private let appearanceState = TasksAppearance()

    /// The pane's tab title (localized).
    public static var paneTitle: String { TasksStrings.title }

    public init(model: TasksModel, layout: @escaping @MainActor () -> TasksLayout) {
        self.model = model
        super.init(frame: .zero)
        wantsLayer = true
        let hosting = NSHostingView(rootView: TasksRoot(model: model, appearance: appearanceState, layout: layout))
        hosting.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: trailingAnchor),
            hosting.topAnchor.constraint(equalTo: topAnchor),
            hosting.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// A fixed layout (demos and snapshots).
    public convenience init(model: TasksModel, layout: TasksLayout) {
        self.init(model: model, layout: { layout })
    }

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
            // The glyph knock-out color stays opaque; the page itself
            // paints the pane's fill (`Palette.paneFill`).
            let background = Palette.contentBackground.withAlphaComponent(1)
            layer?.backgroundColor = nil
            let tokens = themeTokens
            let ansi = tokens.ansi.map { rgb in
                Self.color(ThemeTokens.readable(rgb, over: tokens.contentBackground, minimum: ThemeTokens.minimumMarkContrast).nsColor)
            }
            return TasksColors(
                background: Self.color(background), surface: Self.color(Palette.paneFill), elevated: Self.color(Palette.elevatedBackground),
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

/// Reads the layout and the resolved colors in a tracked scope, so a
/// settings or theme change updates the pane live.
struct TasksRoot: View {
    let model: TasksModel
    let appearance: TasksAppearance
    let layout: @MainActor () -> TasksLayout

    var body: some View {
        TasksView(model: model, layout: layout())
            .environment(\.tasksColors, appearance.colors)
    }
}
