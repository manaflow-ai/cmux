public import AppKit

/// One backdrop picture, aspect-filled and clipped to the view's rounded bounds: a theme's sidebar
/// header (`appearance.sidebarHeader.*`, `ThemeFlourishes.sidebarHeader`). The picture comes from
/// the shared decode cache (``BackdropImageStore``): one decoded at a time per picture for the whole
/// app, off the main actor, and a picture already decoded shows at once. A light/dark pair shows
/// the side of the view's appearance. Decoration only: it takes no clicks and has no accessibility
/// element.
@MainActor
public final class BackdropPictureView: NSView {
    private let images: BackdropImageStore
    /// The picture asked for and the appearance side it was loaded in.
    private var loaded: (selection: BackdropSelection, dark: Bool)?
    private var load: Task<Void, Never>?

    /// The picture to show; nil shows none.
    public var selection: BackdropSelection? {
        didSet { if selection != oldValue { refresh() } }
    }

    /// The corner radius of the clip.
    public var cornerRadius: CGFloat {
        get { layer?.cornerRadius ?? 0 }
        set { layer?.cornerRadius = newValue }
    }

    /// Creates an empty picture view whose pictures come from `images`.
    public init(frame frameRect: NSRect = .zero, images: BackdropImageStore = .shared) {
        self.images = images
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.cornerCurve = .continuous
        layer?.contentsGravity = .resizeAspectFill
        layer?.actions = ["contents": NSNull()]
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override public func hitTest(_ point: NSPoint) -> NSView? { nil }
    override public func isAccessibilityElement() -> Bool { false }

    override public func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refresh()
    }

    private func refresh() {
        let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        guard let selection else {
            load?.cancel()
            loaded = nil
            layer?.contents = nil
            return
        }
        // The same picture in the same side: nothing to do (an appearance change of a single picture too).
        if let loaded, loaded.selection == selection, loaded.dark == dark || !selection.followsAppearance { return }
        loaded = (selection, dark)
        load?.cancel()
        // Resolved first: the store keys a decoded pair side by the side itself.
        let shown = selection.resolved(dark: dark)
        if let ready = images.cached(shown, dark: dark) {
            layer?.contents = ready
            return
        }
        load = Task { [weak self, images] in
            let image = await images.image(shown, dark: dark)
            guard !Task.isCancelled, let self else { return }
            self.layer?.contents = image
        }
    }
}
