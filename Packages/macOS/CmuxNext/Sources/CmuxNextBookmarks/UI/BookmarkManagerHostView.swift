public import AppKit
public import CmuxNextDesign
import SwiftUI

/// Hosts the manager page in a browser tab's content area. Resolves the
/// page colors in this view's theme scope (room, workspace) and again on
/// every theme change.
public final class BookmarkManagerHostView: NSView, VisibilityGatedContent {
    public let model: BookmarkManagerModel
    private let gate: VisibilityGatedHostingView

    /// Its SwiftUI leaves the hierarchy while the tab is hidden (``VisibilityGatedHostingView``).
    public var visibilityGate: VisibilityGatedHostingView? { gate }

    public init(model: BookmarkManagerModel) {
        self.model = model
        gate = VisibilityGatedHostingView(owner: "BookmarkManagerHostView") { BookmarkManagerView(model: model) }
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

    nonisolated public override var wantsUpdateLayer: Bool { true }

    public override func updateLayer() { resolveColors() }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        resolveColors()
    }

    // visibility-walk-allow: a few palette colors stored into the SwiftUI model only when they differ, in the change's turn so a shown manager never draws one frame in the old colors; one manager per window
    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        resolveColors()
    }

    private func resolveColors() {
        let colors = performWithTheme {
            layer?.backgroundColor = nil
            return BookmarkPageColors.resolve()
        }
        if model.colors != colors { model.colors = colors }
    }
}
