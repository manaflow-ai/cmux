public import AppKit
public import CmuxNextDesign
import SwiftUI

/// Hosts the Stashed page (as a top page). Resolves the History page's
/// colors in this view's theme scope, again on every theme change, and reads
/// the groups again each time it shows. Its OneTab paste box (`draft`) is
/// its own, and closes when the page closes or hides.
public final class StashPageHostView: NSView, VisibilityGatedContent {
    public let model: StashPageModel
    public let draft: StashImportDraft
    private let appearanceState = HistoryPageAppearance()
    private var gate: VisibilityGatedHostingView?

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
        resolveColors()
        // task-owner: one stash.list read; the model drops a stale reply by generation
        if window != nil { Task { [model] in await model.reload() } } else { draft.close() }
    }

    public override func viewDidHide() {
        super.viewDidHide()
        draft.close()
    }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        resolveColors()
    }

    private func resolveColors() {
        let colors = HistoryPageHostView.colors(in: self)
        if appearanceState.colors != colors { appearanceState.colors = colors }
    }
}
