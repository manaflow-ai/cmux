public import AppKit
import ObjectiveC

/// Applies native `NSGlassEffectView` window chrome when available and preserves
/// the legacy `NSVisualEffectView` fallback for older macOS releases.
@MainActor
public final class WindowGlassEffect: WindowGlassEffectManaging {
    static let backgroundIdentifier = NSUserInterfaceItemIdentifier("cmux.windowGlassBackground")
    static let rootIdentifier = NSUserInterfaceItemIdentifier("cmux.windowGlassRoot")
    static let foregroundContainerViewIdentifier = NSUserInterfaceItemIdentifier("cmux.windowGlassForeground")

    private static var glassRootViewKey: UInt8 = 0
    private static var fallbackBackgroundViewKey: UInt8 = 0
    private static var originalContentViewKey: UInt8 = 0
    private static var originalContentLayoutStateKey: UInt8 = 0

    /// Creates a window glass effect service.
    public init() {}

    /// Identifier assigned to the native or fallback glass background view.
    public var backgroundViewIdentifier: NSUserInterfaceItemIdentifier {
        Self.backgroundIdentifier
    }

    /// Identifier assigned to the root glass container view.
    public var rootViewIdentifier: NSUserInterfaceItemIdentifier {
        Self.rootIdentifier
    }

    /// Identifier assigned to the foreground content container view.
    public var foregroundContainerIdentifier: NSUserInterfaceItemIdentifier {
        Self.foregroundContainerViewIdentifier
    }

    /// Whether native `NSGlassEffectView` is present on this macOS runtime.
    public var isAvailable: Bool {
        NSClassFromString("NSGlassEffectView") != nil
    }

    /// Applies the glass treatment to `window`.
    ///
    /// - Returns: `true` when the window's root glass hierarchy changed.
    @discardableResult
    public func apply(
        to window: NSWindow,
        tintColor: NSColor? = nil,
        style: WindowGlassEffectStyle? = nil
    ) -> Bool {
        guard let currentContentView = window.contentView else { return false }
        guard isAvailable else {
            return applyFallback(to: window, contentView: currentContentView, tintColor: tintColor)
        }
        removeFallback(from: window)

        let topOffset = glassTopOffset(for: window, contentView: currentContentView)
        let cornerRadius = windowCornerRadius(for: window)

        if let rootView = activeRootView(for: window) {
            rootView.configure(
                topOffset: topOffset,
                tintColor: tintColor,
                style: style,
                cornerRadius: cornerRadius,
                isKeyWindow: window.isKeyWindow
            )
            return false
        }

        let originalContentView = currentContentView
        let layoutState = OriginalContentLayoutState(view: originalContentView)
        let rootView = GlassRootView(
            frame: originalContentView.frame,
            topOffset: topOffset,
            tintColor: tintColor,
            style: style,
            cornerRadius: cornerRadius,
            isKeyWindow: window.isKeyWindow
        )
        window.contentView = rootView
        rootView.attachOriginalContentView(originalContentView)

        objc_setAssociatedObject(window, &Self.glassRootViewKey, rootView, .OBJC_ASSOCIATION_RETAIN)
        objc_setAssociatedObject(window, &Self.originalContentViewKey, originalContentView, .OBJC_ASSOCIATION_RETAIN)
        objc_setAssociatedObject(window, &Self.originalContentLayoutStateKey, layoutState, .OBJC_ASSOCIATION_RETAIN)
        return true
    }

    /// Updates the tint on an already-applied native or fallback glass effect.
    public func updateTint(to window: NSWindow, color: NSColor?) {
        if let rootView = activeRootView(for: window) {
            rootView.configure(
                topOffset: glassTopOffset(for: window, contentView: window.contentView),
                tintColor: color,
                style: nil,
                cornerRadius: windowCornerRadius(for: window),
                isKeyWindow: window.isKeyWindow
            )
        } else if let fallbackView = fallbackBackgroundView(for: window) {
            fallbackView.configure(
                tintColor: color,
                style: nil,
                cornerRadius: windowCornerRadius(for: window),
                isKeyWindow: window.isKeyWindow
            )
        }
    }

    /// Returns the foreground container installed above the glass background.
    public func foregroundContainer(for window: NSWindow) -> NSView? {
        activeRootView(for: window)?.foregroundContainer
    }

    /// Returns the original content view preserved by the glass root.
    public func originalContentView(for window: NSWindow) -> NSView? {
        if let rootView = activeRootView(for: window),
           let originalContentView = rootView.originalContentView {
            return originalContentView
        }
        return objc_getAssociatedObject(window, &Self.originalContentViewKey) as? NSView
    }

    /// Returns the overlay installation target inside the glass foreground.
    public func portalInstallationTarget(for window: NSWindow) -> WindowContentOverlayInstallationTarget? {
        guard let rootView = activeRootView(for: window),
              let originalContentView = originalContentView(for: window),
              originalContentView.superview === rootView.foregroundContainer else {
            return nil
        }
        return WindowContentOverlayInstallationTarget(
            container: rootView.foregroundContainer,
            reference: originalContentView
        )
    }

    /// Removes native or fallback glass from `window`.
    ///
    /// - Returns: `true` when any glass hierarchy was removed.
    @discardableResult
    public func remove(from window: NSWindow) -> Bool {
        if !removeNativeRoot(from: window) {
            return removeFallback(from: window)
        }
        removeFallback(from: window)
        return true
    }

    private func activeRootView(for window: NSWindow) -> GlassRootView? {
        if let rootView = window.contentView as? GlassRootView {
            return rootView
        }
        guard let rootView = objc_getAssociatedObject(window, &Self.glassRootViewKey) as? GlassRootView,
              window.contentView === rootView else {
            return nil
        }
        return rootView
    }

    private func fallbackBackgroundView(for window: NSWindow) -> GlassBackgroundView? {
        objc_getAssociatedObject(window, &Self.fallbackBackgroundViewKey) as? GlassBackgroundView
    }

    @discardableResult
    private func applyFallback(
        to window: NSWindow,
        contentView: NSView,
        tintColor: NSColor?
    ) -> Bool {
        guard let themeFrame = contentView.superview else { return false }
        let cornerRadius = windowCornerRadius(for: window)
        if let fallbackView = fallbackBackgroundView(for: window) {
            if fallbackView.superview !== themeFrame {
                fallbackView.removeFromSuperview()
                attachFallback(fallbackView, to: themeFrame, below: contentView)
            }
            fallbackView.configure(
                tintColor: tintColor,
                style: nil,
                cornerRadius: cornerRadius,
                isKeyWindow: window.isKeyWindow
            )
            return false
        }

        let fallbackView = GlassBackgroundView(
            frame: themeFrame.bounds,
            topOffset: 0,
            tintColor: tintColor,
            style: nil,
            cornerRadius: cornerRadius,
            isKeyWindow: window.isKeyWindow
        )
        attachFallback(fallbackView, to: themeFrame, below: contentView)
        objc_setAssociatedObject(window, &Self.fallbackBackgroundViewKey, fallbackView, .OBJC_ASSOCIATION_RETAIN)
        return true
    }

    private func attachFallback(
        _ fallbackView: GlassBackgroundView,
        to themeFrame: NSView,
        below contentView: NSView
    ) {
        fallbackView.removeFromSuperview()
        fallbackView.translatesAutoresizingMaskIntoConstraints = false
        themeFrame.addSubview(fallbackView, positioned: .below, relativeTo: contentView)
        NSLayoutConstraint.activate([
            fallbackView.topAnchor.constraint(equalTo: themeFrame.topAnchor),
            fallbackView.bottomAnchor.constraint(equalTo: themeFrame.bottomAnchor),
            fallbackView.leadingAnchor.constraint(equalTo: themeFrame.leadingAnchor),
            fallbackView.trailingAnchor.constraint(equalTo: themeFrame.trailingAnchor),
        ])
    }

    private func glassTopOffset(for window: NSWindow, contentView: NSView?) -> CGFloat {
        guard let themeFrame = contentView?.superview ?? window.contentView?.superview else {
            return 0
        }
        return -max(0, themeFrame.safeAreaInsets.top)
    }

    private func windowCornerRadius(for window: NSWindow) -> CGFloat? {
        guard window.responds(to: Selector(("_cornerRadius"))) else {
            return nil
        }
        return window.value(forKey: "_cornerRadius") as? CGFloat
    }

    @discardableResult
    private func removeNativeRoot(from window: NSWindow) -> Bool {
        guard let rootView = activeRootView(for: window) else {
            return false
        }

        if let originalContentView = originalContentView(for: window) {
            originalContentView.removeFromSuperview()
            originalContentView.frame = rootView.bounds
            if let layoutState = objc_getAssociatedObject(
                window,
                &Self.originalContentLayoutStateKey
            ) as? OriginalContentLayoutState {
                layoutState.restore(to: originalContentView)
            }
            window.contentView = originalContentView
        }

        objc_setAssociatedObject(window, &Self.glassRootViewKey, nil, .OBJC_ASSOCIATION_RETAIN)
        objc_setAssociatedObject(window, &Self.originalContentViewKey, nil, .OBJC_ASSOCIATION_RETAIN)
        objc_setAssociatedObject(window, &Self.originalContentLayoutStateKey, nil, .OBJC_ASSOCIATION_RETAIN)
        return true
    }

    @discardableResult
    private func removeFallback(from window: NSWindow) -> Bool {
        guard let fallbackView = fallbackBackgroundView(for: window) else { return false }
        fallbackView.removeFromSuperview()
        objc_setAssociatedObject(window, &Self.fallbackBackgroundViewKey, nil, .OBJC_ASSOCIATION_RETAIN)
        return true
    }

}
