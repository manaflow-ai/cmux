public import AppKit
import ObjectiveC

/// Coordinates native AppKit titlebar backdrop hiding and restoration.
@MainActor
public final class NativeTitlebarBackdropCoordinator {
    private static var unifiedTitlebarLayerAppliedKey: UInt8 = 0
    private static var unifiedTitlebarLayerColorKey: UInt8 = 0
    private static var unifiedTitlebarLayerOpaqueKey: UInt8 = 0
    private static var unifiedTitlebarHiddenAppliedKey: UInt8 = 0
    private static var unifiedTitlebarHiddenKey: UInt8 = 0
    private static var unifiedTitlebarTransparencyAppliedKey: UInt8 = 0
    private static var unifiedTitlebarTransparencyKey: UInt8 = 0

    private let fullscreenAuxiliaryWindows: @MainActor () -> [NSWindow]

    /// Creates a coordinator with an injected provider for fullscreen auxiliary windows.
    public init(fullscreenAuxiliaryWindows: @escaping @MainActor () -> [NSWindow]) {
        self.fullscreenAuxiliaryWindows = fullscreenAuxiliaryWindows
    }

    /// Removes the cmux native titlebar backdrop view from a window.
    public func removeNativeTitlebarBackdrop(in window: NSWindow) {
        guard let contentView = window.contentView,
              let themeFrame = contentView.superview else { return }

        let identifier = NSUserInterfaceItemIdentifier("cmux.nativeTitlebarBackdrop")
        let existing = themeFrame.subviews.first { $0.identifier == identifier } as? NativeTitlebarBackdropView
        existing?.removeFromSuperview()
    }

    /// Hides or restores AppKit's native titlebar backdrop views.
    public func syncNativeTitlebarBackdrop(
        in window: NSWindow,
        enabled: Bool,
        usesGlassStyle: Bool
    ) {
        guard let titlebarContainer = nativeTitlebarContainer(in: window) else { return }
        let titlebarViews = collectNativeTitlebarViews(in: titlebarContainer)

        if enabled {
            rememberNativeTitlebarTransparencyState(window)
            rememberNativeTitlebarBackdropState(
                titlebarContainer: titlebarContainer,
                titlebarView: titlebarViews.titlebarView,
                titlebarBackgroundViews: titlebarViews.titlebarBackgroundViews,
                effectViews: titlebarViews.effectViews
            )
        } else {
            restoreNativeTitlebarBackdropState(
                titlebarContainer: titlebarContainer,
                titlebarView: titlebarViews.titlebarView,
                titlebarBackgroundViews: titlebarViews.titlebarBackgroundViews,
                effectViews: titlebarViews.effectViews
            )
            restoreNativeTitlebarTransparencyState(window)
            return
        }

        titlebarContainer.wantsLayer = true
        titlebarContainer.layer?.backgroundColor = usesGlassStyle ? NSColor.clear.cgColor : nil
        titlebarContainer.layer?.isOpaque = false
        titlebarViews.titlebarView?.wantsLayer = true
        titlebarViews.titlebarView?.layer?.backgroundColor = usesGlassStyle ? NSColor.clear.cgColor : nil
        titlebarViews.titlebarView?.layer?.isOpaque = false
        for titlebarBackgroundView in titlebarViews.titlebarBackgroundViews {
            titlebarBackgroundView.isHidden = true
        }
        for effectView in titlebarViews.effectViews {
            effectView.isHidden = true
        }
        window.titlebarAppearsTransparent = true
    }

    /// Hides standard titlebar controls when fullscreen or minimal mode needs custom controls.
    public func setTitlebarControlsHidden(
        _ hidden: Bool,
        in window: NSWindow,
        isMinimalMode: Bool
    ) {
        let controlsId = NSUserInterfaceItemIdentifier("cmux.titlebarControls")
        let shouldHide = hidden || isMinimalMode
        for accessory in window.titlebarAccessoryViewControllers {
            if accessory.view.identifier == controlsId {
                accessory.isHidden = shouldHide
                accessory.view.alphaValue = shouldHide ? 0 : 1
            }
        }
    }

    private func rememberNativeTitlebarBackdropState(
        titlebarContainer: NSView,
        titlebarView: NSView?,
        titlebarBackgroundViews: [NSView],
        effectViews: [NSView]
    ) {
        rememberNativeTitlebarLayerState(titlebarContainer)
        if let titlebarView {
            rememberNativeTitlebarLayerState(titlebarView)
        }
        for titlebarBackgroundView in titlebarBackgroundViews {
            rememberNativeTitlebarHiddenState(titlebarBackgroundView)
        }
        for effectView in effectViews {
            rememberNativeTitlebarHiddenState(effectView)
        }
    }

    private func restoreNativeTitlebarBackdropState(
        titlebarContainer: NSView,
        titlebarView: NSView?,
        titlebarBackgroundViews: [NSView],
        effectViews: [NSView]
    ) {
        restoreNativeTitlebarLayerState(titlebarContainer)
        if let titlebarView {
            restoreNativeTitlebarLayerState(titlebarView)
        }
        for titlebarBackgroundView in titlebarBackgroundViews {
            restoreNativeTitlebarHiddenState(titlebarBackgroundView)
        }
        for effectView in effectViews {
            restoreNativeTitlebarHiddenState(effectView)
        }
    }

    private func rememberNativeTitlebarLayerState(_ view: NSView) {
        guard objc_getAssociatedObject(view, &Self.unifiedTitlebarLayerAppliedKey) == nil else { return }

        objc_setAssociatedObject(view, &Self.unifiedTitlebarLayerAppliedKey, NSNumber(value: true), .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        objc_setAssociatedObject(view, &Self.unifiedTitlebarLayerColorKey, view.layer?.backgroundColor ?? NSNull(), .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        objc_setAssociatedObject(view, &Self.unifiedTitlebarLayerOpaqueKey, view.layer.map { NSNumber(value: $0.isOpaque) } ?? NSNull(), .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }

    private func restoreNativeTitlebarLayerState(_ view: NSView) {
        guard objc_getAssociatedObject(view, &Self.unifiedTitlebarLayerAppliedKey) != nil else { return }

        if let storedColor = objc_getAssociatedObject(view, &Self.unifiedTitlebarLayerColorKey),
           !(storedColor is NSNull) {
            view.layer?.backgroundColor = (storedColor as! CGColor)
        } else {
            view.layer?.backgroundColor = nil
        }

        if let isOpaque = objc_getAssociatedObject(view, &Self.unifiedTitlebarLayerOpaqueKey) as? NSNumber {
            view.layer?.isOpaque = isOpaque.boolValue
        }

        objc_setAssociatedObject(view, &Self.unifiedTitlebarLayerAppliedKey, nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        objc_setAssociatedObject(view, &Self.unifiedTitlebarLayerColorKey, nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        objc_setAssociatedObject(view, &Self.unifiedTitlebarLayerOpaqueKey, nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }

    private func rememberNativeTitlebarHiddenState(_ view: NSView) {
        guard objc_getAssociatedObject(view, &Self.unifiedTitlebarHiddenAppliedKey) == nil else { return }

        objc_setAssociatedObject(view, &Self.unifiedTitlebarHiddenAppliedKey, NSNumber(value: true), .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        objc_setAssociatedObject(view, &Self.unifiedTitlebarHiddenKey, NSNumber(value: view.isHidden), .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }

    private func restoreNativeTitlebarHiddenState(_ view: NSView) {
        guard objc_getAssociatedObject(view, &Self.unifiedTitlebarHiddenAppliedKey) != nil else { return }

        if let hidden = objc_getAssociatedObject(view, &Self.unifiedTitlebarHiddenKey) as? NSNumber {
            view.isHidden = hidden.boolValue
        }

        objc_setAssociatedObject(view, &Self.unifiedTitlebarHiddenAppliedKey, nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        objc_setAssociatedObject(view, &Self.unifiedTitlebarHiddenKey, nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }

    private func rememberNativeTitlebarTransparencyState(_ window: NSWindow) {
        guard objc_getAssociatedObject(window, &Self.unifiedTitlebarTransparencyAppliedKey) == nil else { return }
        objc_setAssociatedObject(window, &Self.unifiedTitlebarTransparencyAppliedKey, NSNumber(value: true), .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        objc_setAssociatedObject(window, &Self.unifiedTitlebarTransparencyKey, NSNumber(value: window.titlebarAppearsTransparent), .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }

    private func restoreNativeTitlebarTransparencyState(_ window: NSWindow) {
        guard objc_getAssociatedObject(window, &Self.unifiedTitlebarTransparencyAppliedKey) != nil else { return }

        if let value = objc_getAssociatedObject(window, &Self.unifiedTitlebarTransparencyKey) as? NSNumber {
            window.titlebarAppearsTransparent = value.boolValue
        }

        objc_setAssociatedObject(window, &Self.unifiedTitlebarTransparencyAppliedKey, nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        objc_setAssociatedObject(window, &Self.unifiedTitlebarTransparencyKey, nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }

    private func nativeTitlebarContainer(in window: NSWindow) -> NSView? {
        if !window.styleMask.contains(.fullScreen) {
            return window.contentView.flatMap {
                firstNativeDescendant(
                    in: nativeRootView(from: $0),
                    className: "NSTitlebarContainerView",
                    includeRoot: true
                )
            }
        }

        for candidate in fullscreenAuxiliaryWindows() where candidate.className == "NSToolbarFullScreenWindow" {
            guard candidate.parent == window else { continue }
            if let contentView = candidate.contentView {
                return firstNativeDescendant(
                    in: nativeRootView(from: contentView),
                    className: "NSTitlebarContainerView",
                    includeRoot: true
                )
            }
        }

        return nil
    }

    private func nativeRootView(from view: NSView) -> NSView {
        var root = view
        while let superview = root.superview {
            root = superview
        }
        return root
    }

    private struct NativeTitlebarViews {
        var titlebarView: NSView?
        var titlebarBackgroundViews: [NSView] = []
        var effectViews: [NSView] = []
    }

    private func collectNativeTitlebarViews(in view: NSView) -> NativeTitlebarViews {
        var result = NativeTitlebarViews()
        collectNativeTitlebarViews(in: view, result: &result, includeRoot: true)
        return result
    }

    private func collectNativeTitlebarViews(
        in view: NSView,
        result: inout NativeTitlebarViews,
        includeRoot: Bool = false
    ) {
        if includeRoot {
            collectNativeTitlebarView(view, result: &result)
        }
        for subview in view.subviews {
            collectNativeTitlebarView(subview, result: &result)
            collectNativeTitlebarViews(in: subview, result: &result)
        }
    }

    private func collectNativeTitlebarView(_ view: NSView, result: inout NativeTitlebarViews) {
        switch String(describing: type(of: view)) {
        case "NSTitlebarView" where result.titlebarView == nil:
            result.titlebarView = view
        case "NSTitlebarBackgroundView":
            result.titlebarBackgroundViews.append(view)
        case "NSVisualEffectView":
            result.effectViews.append(view)
        default:
            break
        }
    }

    private func firstNativeDescendant(
        in view: NSView,
        className: String,
        includeRoot: Bool = false
    ) -> NSView? {
        if includeRoot, String(describing: type(of: view)) == className {
            return view
        }

        for subview in view.subviews {
            if String(describing: type(of: subview)) == className {
                return subview
            }
            if let found = firstNativeDescendant(in: subview, className: className) {
                return found
            }
        }

        return nil
    }
}

private final class NativeTitlebarBackdropView: NSView {
    override var isOpaque: Bool {
        layer?.isOpaque ?? false
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}
