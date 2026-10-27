import AppKit
import CmuxNextActions
import CmuxNextDesign
import SwiftUI
import CmuxNextHistory
import CmuxNextWakeups

/// Hosts the vault list (the vault page's content and the right sidebar's
/// Vault section). Resolves the list colors in this view's theme scope, again
/// on every theme change. Row gestures run the `vault*` actions through the
/// registry with the row's session.
final class VaultHostView: NSView, VisibilityGatedContent {
    let vault: SessionVault
    private let appearanceState = VaultAppearance()
    private var gate: VisibilityGatedHostingView?
    /// The view's place in the visibility tree (a page tab or the right sidebar's section): a theme change while it
    /// is hidden resolves the colors once, on show.
    private let visibility = ViewVisibility("vault")
    private var visibilityNode: VisibilityNode { visibility.node }
    /// How many times the list's colors were resolved (tests: a hidden vault resolves none until it shows).
    private(set) var colorResolves = 0

    /// Its SwiftUI leaves the hierarchy while the vault tab is hidden (``VisibilityGatedHostingView``); the
    /// right sidebar's section follows no node.
    var visibilityGate: VisibilityGatedHostingView? { gate }

    /// - Parameter readsOnAppear: Whether the list reads the vault when it appears (the right sidebar's
    ///   section). The vault page tab reads on each show itself (`VaultPageTab.setContentVisible`), and its
    ///   gated list appears again on each show, so it passes false.
    init(vault: SessionVault, registry: ActionRegistry, readsOnAppear: Bool = true) {
        self.vault = vault
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
        let gate = VisibilityGatedHostingView(owner: "VaultHostView") {
            VaultListView(vault: vault, appearance: appearance, actions: actions, readsOnAppear: readsOnAppear)
        }
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
        visibility.place(in: window)
        resolveColors()
    }

    // R-hide: hiding forwards to the node.
    override func viewDidHide() {
        super.viewDidHide()
        visibilityNode.set(.hidden)
    }

    override func viewDidUnhide() {
        super.viewDidUnhide()
        visibilityNode.set(.visible)
    }

    // R-appear: the colors feed the SwiftUI list, so a hidden vault resolves them on show.
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        visibilityNode.deferUntilVisible(key: "VaultHostView.appearance") { [weak self] in self?.resolveColors() }
    }

    private func resolveColors() {
        colorResolves += 1
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
