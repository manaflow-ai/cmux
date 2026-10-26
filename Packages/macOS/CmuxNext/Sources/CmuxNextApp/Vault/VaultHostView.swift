import AppKit
import CmuxNextActions
import CmuxNextDesign
import SwiftUI
import CmuxNextHistory

/// Hosts the vault list (the vault page's content and the right sidebar's
/// Vault section). Resolves the list colors in this view's theme scope, again
/// on every theme change. Row gestures run the `vault*` actions through the
/// registry with the row's session.
final class VaultHostView: NSView, VisibilityGatedContent {
    let vault: SessionVault
    /// Whether this view reads the vault each time it moves into a window (the right sidebar's section).
    /// The vault page tab reads on each show itself (`VaultPageTab.setContentVisible`), so its view does not.
    private let readsInWindow: Bool
    private let appearanceState = VaultAppearance()
    private var gate: VisibilityGatedHostingView?

    /// Its SwiftUI leaves the hierarchy while the vault tab is hidden (``VisibilityGatedHostingView``); the
    /// right sidebar's section follows no node.
    var visibilityGate: VisibilityGatedHostingView? { gate }

    init(vault: SessionVault, registry: ActionRegistry, readsInWindow: Bool = true) {
        self.vault = vault
        self.readsInWindow = readsInWindow
        super.init(frame: NSRect(x: 0, y: 0, width: 320, height: 480))
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        let actions = VaultRowActions(
            perform: { [weak vault, weak registry] id, session in
                vault?.selection = session
                registry?.perform(id, invocation: ActionInvocation(arguments: ["session": .string(session)]))
            },
            select: { [weak vault] id in vault?.selection = id })
        let appearance = appearanceState
        let gate = VisibilityGatedHostingView(owner: "VaultHostView") { VaultListView(vault: vault, appearance: appearance, actions: actions) }
        gate.translatesAutoresizingMaskIntoConstraints = false
        addSubview(gate)
        NSLayoutConstraint.activate([
            gate.leadingAnchor.constraint(equalTo: leadingAnchor),
            gate.trailingAnchor.constraint(equalTo: trailingAnchor),
            gate.topAnchor.constraint(equalTo: topAnchor),
            gate.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        self.gate = gate
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
        // task-owner: one vault read each time the section moves into a window; the list shows its rows
        if readsInWindow, window != nil { Task { [vault] in await vault.reload() } }
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
