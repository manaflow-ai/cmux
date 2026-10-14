public import AppKit
import SwiftUI

/// Hosts the Stashed page (as a top page). Resolves the History page's
/// colors in this view's theme scope, again on every theme change, and reads
/// the groups again each time it shows.
public final class StashPageHostView: NSView {
    public let model: StashPageModel
    private let appearanceState = HistoryPageAppearance()

    public init(model: StashPageModel) {
        self.model = model
        super.init(frame: .zero)
        wantsLayer = true
        let hosting = NSHostingView(rootView: StashPageView(model: model, appearance: appearanceState))
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

    public override var wantsUpdateLayer: Bool { true }

    public override func updateLayer() { resolveColors() }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        resolveColors()
        // task-owner: one stash.list read; the model drops a stale reply by generation
        if window != nil { Task { [model] in await model.reload() } }
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
