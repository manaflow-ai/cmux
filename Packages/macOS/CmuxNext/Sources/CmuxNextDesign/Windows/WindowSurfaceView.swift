public import AppKit
import CmuxNextCompat

/// The content view every window kit window gets (plans/cmux-next/windows.md,
/// one backdrop rule): the window's one backdrop, the same material and
/// tint the main window's root draws, at the bottom, and the owner's
/// content filling it above. It repaints on every theme or Reduce
/// Transparency change, so each window shows the same color at the same
/// opacity as the main window.
public final class WindowSurfaceView: NSView, WindowSurfacePainting {
    /// The owner's content (`NSWindow.installedContent`).
    public let content: NSView
    /// The window's one material and tint.
    public let backdropView: WindowMaterialView
    private let reduceTransparency: @MainActor () -> Bool
    private var displayOptionsObserver: MainActorObservation?

    /// - Parameter activeLook: The app's ``ActiveLookScope`` (made once by `AppServices`): the
    ///   backdrop's glass keeps its key look while the window is not key; nil follows the key state.
    public init(content: NSView, activeLook: ActiveLookScope?,
                reduceTransparency: @escaping @MainActor () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency }) {
        self.content = content
        backdropView = WindowMaterialView(frame: .zero, images: .shared, activeLook: activeLook)
        self.reduceTransparency = reduceTransparency
        super.init(frame: content.frame.size == .zero ? NSRect(x: 0, y: 0, width: 480, height: 320) : NSRect(origin: .zero, size: content.frame.size))
        wantsLayer = true
        backdropView.frame = bounds
        backdropView.autoresizingMask = [.width, .height]
        addSubview(backdropView)
        content.frame = bounds
        content.autoresizingMask = [.width, .height]
        addSubview(content)
        // queue: .main: the workspace center may post off main; a selector
        // into this main-actor view trapped there.
        displayOptionsObserver = MainActorObservation(NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, center: NSWorkspace.shared.notificationCenter) { [weak self] in
            self?.repaint()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// The backdrop of `window`'s theme scope and Reduce Transparency.
    public func backdrop(in window: NSWindow) -> WindowBackdrop {
        WindowBackdrop(window.themeScope.tokens, reduceTransparency: reduceTransparency(), art: window.themeScope.backdropArt,
                       selection: window.themeScope.backdropSelection, tuning: window.themeScope.appearanceTuning,
                       tintOpacity: window.themeScope.backdropTintOpacity)
    }

    public func paintWindowSurface(of window: NSWindow) {
        let backdrop = backdrop(in: window)
        let surface = window.themeScope.perform { Palette.surfaceBackground }
        paintBackdropSheet(backdrop, surface: surface, backdropView: backdropView)
        window.applyBackdrop(backdrop, surface: surface)
    }

    override public func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        repaint()
    }

    override public func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        repaint()
    }

    private func repaint() {
        if let window { paintWindowSurface(of: window) }
    }
}

extension NSWindow {
    /// The content its owner installed (`install(kind:content:scope:activeLook:)`),
    /// inside the window kit's ``WindowSurfaceView``.
    public var installedContent: NSView? { (contentView as? WindowSurfaceView)?.content ?? contentView }
}
