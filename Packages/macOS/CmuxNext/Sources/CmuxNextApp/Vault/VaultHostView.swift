import AppKit
import CmuxNextActions
import CmuxNextDesign
import SwiftUI
import CmuxNextHistory

/// Hosts the vault list (the vault page's content and the right sidebar's
/// Vault section). Resolves the list colors in this view's theme scope, again
/// on every theme change. Row gestures run the `vault*` actions through the
/// registry with the row's session.
final class VaultHostView: NSView {
    let vault: SessionVault
    private let appearanceState = VaultAppearance()

    init(vault: SessionVault, registry: ActionRegistry) {
        self.vault = vault
        super.init(frame: NSRect(x: 0, y: 0, width: 320, height: 480))
        wantsLayer = true
        let actions = VaultRowActions(
            perform: { [weak vault, weak registry] id, session in
                vault?.selection = session
                registry?.perform(id, invocation: ActionInvocation(arguments: ["session": .string(session)]))
            },
            select: { [weak vault] id in vault?.selection = id })
        let hosting = NSHostingView(rootView: VaultListView(vault: vault, appearance: appearanceState, actions: actions))
        hosting.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: trailingAnchor),
            hosting.topAnchor.constraint(equalTo: topAnchor),
            hosting.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        setAccessibilityIdentifier("cmux.vault")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var acceptsFirstResponder: Bool { true }

    nonisolated override var wantsUpdateLayer: Bool { true }

    override func updateLayer() { resolveColors() }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        resolveColors()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        resolveColors()
    }

    private func resolveColors() {
        let colors = performWithTheme {
            VaultColors(background: .clear, primary: Self.color(Palette.textPrimary), secondary: Self.color(Palette.textSecondary),
                        tertiary: Self.color(Palette.textTertiary), selection: Self.color(Palette.selectionFill),
                        live: Self.color(Palette.success))
        }
        if appearanceState.colors != colors { appearanceState.colors = colors }
    }

    /// A static color: a dynamic one would re-resolve in SwiftUI's appearance, outside this theme scope.
    private static func color(_ color: NSColor) -> Color {
        Color(nsColor: color.usingColorSpace(.sRGB) ?? color)
    }
}
