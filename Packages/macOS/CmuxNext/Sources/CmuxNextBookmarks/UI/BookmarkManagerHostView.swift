public import AppKit
import CmuxNextDesign
import SwiftUI

/// Hosts the manager page in a browser tab's content area. Resolves the
/// page colors in this view's theme scope (room, workspace) and again on
/// every theme change.
public final class BookmarkManagerHostView: NSView {
    public let model: BookmarkManagerModel
    private var hosting: NSHostingView<BookmarkManagerView>?

    public init(model: BookmarkManagerModel) {
        self.model = model
        super.init(frame: .zero)
        wantsLayer = true
        let hosting = NSHostingView(rootView: BookmarkManagerView(model: model))
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

    public override func updateLayer() { resolveColors() }

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
            layer?.backgroundColor = nil
            return BookmarkPageColors.resolve()
        }
        if model.colors != colors { model.colors = colors }
    }
}
