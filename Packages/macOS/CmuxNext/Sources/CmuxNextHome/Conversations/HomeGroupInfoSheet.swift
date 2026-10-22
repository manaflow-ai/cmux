public import AppKit
import CmuxNextDesign

/// The group info sheet's controller: hosts ``HomeGroupInfoView`` over its model. The app
/// presents it as a sheet of the Home page's window and feeds it newer reads of the
/// conversation (`model.update`) while it shows.
public final class HomeGroupInfoSheet: NSViewController {
    /// The sheet's state; the presenter updates it.
    public let model: HomeGroupInfoModel
    /// The sheet closed (Done, Escape, Leave Group…, Invite by Email…).
    public var onClose: @MainActor () -> Void = {}
    private let colors: HomeGroupInfoColors
    /// The sheet's material, under the content: this Mac's glass with no card fill, solid
    /// only under Reduce Transparency (Leo 2026-10-21: "glass is never opaque").
    let surface = OverlaySurfaceView(interactive: true, cornerRadius: 0)

    /// - Parameters:
    ///   - model: The sheet's state and actions.
    ///   - colors: The presenter's theme colors (``HomeGroupInfoColors/resolve()`` in its scope).
    public init(model: HomeGroupInfoModel, colors: HomeGroupInfoColors) {
        self.model = model
        self.colors = colors
        super.init(nibName: nil, bundle: nil)
        model.close = { [weak self] in self?.close() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    public override func loadView() {
        let content = HomeGroupInfoView(model: model, colors: colors)
        content.translatesAutoresizingMaskIntoConstraints = false
        let root = NSView()
        // The sheet is a window of its own: the vibrancy fallback blurs the window behind it.
        surface.samplesBehindWindow = true
        root.addSubview(surface)
        root.addSubview(content)
        surface.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            surface.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            surface.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            surface.topAnchor.constraint(equalTo: root.topAnchor),
            surface.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            content.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            content.topAnchor.constraint(equalTo: root.topAnchor),
            content.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        view = root
    }

    /// Ends the sheet (once).
    public func close() {
        model.stop()
        if let presenting = presentingViewController {
            presenting.dismiss(self)
        } else if let window = view.window, let parent = window.sheetParent {
            parent.endSheet(window)
        }
        let closed = onClose
        onClose = {}
        closed()
    }
}
