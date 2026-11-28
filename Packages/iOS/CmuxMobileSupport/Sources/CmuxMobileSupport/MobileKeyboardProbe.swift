#if canImport(UIKit)
public import UIKit

/// The software keyboard as drawn this frame: the system's placeholder for the
/// out-of-process keyboard in the app's text effects window, read from
/// presentation layers. Read-only; `nil` when it cannot be found.
///
/// Used where UIKit gives no live keyboard position: an interactive dismissal
/// when the keyboard layout guide does not follow the keyboard
/// (``MobileKeyboardDock``), and the DEBUG keyboard traces.
@MainActor
public struct MobileKeyboardProbe {
    public init() {}

    /// The drawn keyboard's frame in `window` coordinates, or `nil` when no
    /// keyboard is on screen or the placeholder cannot be found.
    public func drawnFrame(in window: UIWindow) -> CGRect? {
        guard let scene = window.windowScene else { return nil }
        for candidate in scene.windows where NSStringFromClass(type(of: candidate)).contains("TextEffects") {
            guard let host = find(in: candidate, where: { NSStringFromClass(type(of: $0)).contains("RemoteKeyboardPlaceholder") }) else { continue }
            let rect = window.convert(onScreen(host, in: candidate), from: candidate)
            guard rect.height > 1, rect.minY < window.bounds.maxY else { return nil }
            return rect
        }
        return nil
    }

    /// The drawn keyboard's top edge in `window` coordinates: the window's
    /// bottom edge when no keyboard is on screen, `nil` when the placeholder
    /// cannot be found.
    public func drawnTop(in window: UIWindow?) -> CGFloat? {
        guard let window, let scene = window.windowScene else { return nil }
        for candidate in scene.windows where NSStringFromClass(type(of: candidate)).contains("TextEffects") {
            guard let host = find(in: candidate, where: { NSStringFromClass(type(of: $0)).contains("RemoteKeyboardPlaceholder") }) else { continue }
            let rect = window.convert(onScreen(host, in: candidate), from: candidate)
            return rect.height > 1 ? min(rect.minY, window.bounds.maxY) : window.bounds.maxY
        }
        return nil
    }

    /// A view's frame in `window` as drawn this frame: the presentation
    /// layers' geometry all the way up.
    public func onScreen(_ view: UIView, in window: UIView) -> CGRect {
        var layer: CALayer? = view.layer
        var rect = (view.layer.presentation() ?? view.layer).bounds
        while let current = layer, current !== window.layer {
            let p = current.presentation() ?? current
            guard let superlayer = current.superlayer else { break }
            let sp = superlayer.presentation() ?? superlayer
            rect = p.convert(rect, to: sp)
            layer = superlayer
        }
        return rect
    }

    /// The first view under `view` (itself included) that matches.
    public func find(in view: UIView, where match: (UIView) -> Bool) -> UIView? {
        if match(view) { return view }
        for sub in view.subviews { if let found = find(in: sub, where: match) { return found } }
        return nil
    }
}
#endif
