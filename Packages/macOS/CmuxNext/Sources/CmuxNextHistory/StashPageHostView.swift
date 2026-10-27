public import AppKit
public import CmuxNextDesign
import CmuxNextWakeups
import SwiftUI

/// Hosts the Stashed page (as a top page). Resolves the History page's
/// colors in this view's theme scope, again on every theme change (once, on
/// show, for a hidden page), and reads the groups again each time it shows.
/// Its OneTab paste box (`draft`) is its own, and closes when the page closes
/// or hides.
public final class StashPageHostView: NSView, VisibilityGatedContent {
    public let model: StashPageModel
    public let draft: StashImportDraft
    private let appearanceState = HistoryPageAppearance()
    private var gate: VisibilityGatedHostingView?
    /// The view's place in the visibility tree: a theme change while the page is hidden resolves the colors once,
    /// on show.
    private let visibility = ViewVisibility("stash")
    private var visibilityNode: VisibilityNode { visibility.node }
    /// How many times the colors were resolved (tests: a hidden page resolves none until it shows).
    private(set) var colorResolves = 0

    /// Its SwiftUI leaves the hierarchy while the tab is hidden (``VisibilityGatedHostingView``).
    public var visibilityGate: VisibilityGatedHostingView? { gate }

    public init(model: StashPageModel, draft: StashImportDraft) {
        self.model = model
        self.draft = draft
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        let view = StashPageView(model: model, draft: draft, appearance: appearanceState) { [weak self] in self?.window }
        let gate = VisibilityGatedHostingView(owner: "StashPageHostView") { view }
        gate.translatesAutoresizingMaskIntoConstraints = false
        addSubview(gate)
        NSLayoutConstraint.activate([
            gate.leadingAnchor.constraint(equalTo: leadingAnchor),
            gate.trailingAnchor.constraint(equalTo: trailingAnchor),
            gate.topAnchor.constraint(equalTo: topAnchor),
            gate.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        self.gate = gate
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    nonisolated public override var wantsUpdateLayer: Bool { true }

    public override func updateLayer() { resolveColors() }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        visibility.place(in: window)
        resolveColors()
        if window != nil { model.start { await $0.reload() } } else { draft.close() }
    }

    // R-hide: hiding forwards to the node.
    // visibility-walk-allow: closing the paste box is the page's own close on hide (as on close), not a hidden-dirty flag; nothing waits for the show
    public override func viewDidHide() {
        super.viewDidHide()
        visibilityNode.set(.hidden)
        draft.close()
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

    private static let appearanceKey = "StashPageHostView.appearance"

    private func resolveColors() {
        colorResolves += 1
        let colors = HistoryPageHostView.colors(in: self)
        if appearanceState.colors != colors { appearanceState.colors = colors }
    }
}
