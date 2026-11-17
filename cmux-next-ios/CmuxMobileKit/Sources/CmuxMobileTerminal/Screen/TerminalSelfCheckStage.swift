#if os(iOS)
import UIKit

/// Where the Mac's grid is drawn, in window points: the pixel matrix (`TerminalBenchProbe`,
/// DEBUG) and the lean terminal self-check (``TerminalSelfCheckStage``) compare exactly those
/// pixels.
public struct TerminalGridGeometry: Sendable, Equatable {
    /// The Mac's whole grid (columns × rows cells), panned as it is (it may run past
    /// the window's edges).
    public var grid: CGRect
    /// The cursor's cell, when it is in the viewport.
    public var cursor: CGRect?
    /// One cell of the grid.
    public var cell: CGSize
    /// The terminal shows a full-screen app (the alternate screen's layout).
    public var fullScreen: Bool
    /// The window's bounds and scale.
    public var window: CGRect
    public var scale: CGFloat

    public init(grid: CGRect, cursor: CGRect?, cell: CGSize, fullScreen: Bool, window: CGRect, scale: CGFloat) {
        self.grid = grid
        self.cursor = cursor
        self.cell = cell
        self.fullScreen = fullScreen
        self.window = window
        self.scale = scale
    }
}

/// The lean terminal self-check's stage (`cmux device self-check`, a hidden debug action the
/// Mac starts): the app's own terminal screens, each drawing one model, stacked on one frame in
/// a window over the app, so every one lays out the same and draws in the same frames. The
/// window never becomes key (the keyboard and the focused text field stay where they were)
/// and is gone after ``tearDown()``.
@MainActor
public final class TerminalSelfCheckStage {
    private let window: UIWindow
    private let root = UIViewController()
    private let box = UIView()
    private var controllers: [TerminalViewController] = []

    /// A stage over `scene`'s windows.
    public init(scene: UIWindowScene) {
        window = UIWindow(windowScene: scene)
        window.windowLevel = .alert + 1
        window.backgroundColor = .black
        root.view.backgroundColor = .black
        box.clipsToBounds = true
        root.view.addSubview(box)
        window.rootViewController = root
        window.isHidden = false
        box.frame = root.view.bounds
    }

    /// One terminal screen per model, each filling the stage, the last on top.
    public func show(_ models: [TerminalModel]) {
        clear()
        for model in models {
            let controller = TerminalViewController(model: model)
            root.addChild(controller)
            controller.view.frame = box.bounds
            controller.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            box.addSubview(controller.view)
            controller.didMove(toParent: root)
            controllers.append(controller)
        }
        window.layoutIfNeeded()
    }

    /// The stage's size: the window's (`nil`) or `size` from its top-left corner (a phone turned
    /// on its side: the screens lay out again for it, as on a rotation).
    public func resize(to size: CGSize?) {
        box.frame = CGRect(origin: .zero, size: size ?? root.view.bounds.size)
        window.layoutIfNeeded()
    }

    /// Takes the screens out of the window (`false`, as the app going to the background hides
    /// them: Ghostty stops drawing) and puts them back.
    public func setShown(_ shown: Bool) {
        if shown {
            if box.superview == nil { root.view.addSubview(box) }
        } else {
            box.removeFromSuperview()
        }
        window.layoutIfNeeded()
    }

    /// Frames each screen presented so far.
    public var presentedFrames: [Int] { controllers.map(\.presentedFrames) }

    /// Where screen `index` draws the Mac's grid now.
    public func geometry(_ index: Int) -> TerminalGridGeometry? {
        controllers.indices.contains(index) ? controllers[index].benchGeometry() : nil
    }

    /// Pans every screen's grid, if wider than the phone, to its first column or its last.
    public func pan(toEnd: Bool) {
        for controller in controllers { controller.benchPan(toEnd: toEnd) }
        window.layoutIfNeeded()
    }

    /// The pixels screen `index` presented under `rect` (window points), and the part of
    /// `rect` they cover.
    public func pixels(_ index: Int, in rect: CGRect) -> (image: CGImage, rect: CGRect)? {
        controllers.indices.contains(index) ? controllers[index].presentedPixels(in: rect) : nil
    }

    /// The visible stage in window points.
    public var bounds: CGRect { box.superview == nil ? .zero : box.convert(box.bounds, to: nil) }

    private func clear() {
        for controller in controllers {
            controller.willMove(toParent: nil)
            controller.view.removeFromSuperview()
            controller.removeFromParent()
        }
        controllers = []
    }

    /// Removes the screens and the window.
    public func tearDown() {
        clear()
        window.isHidden = true
        window.rootViewController = nil
    }
}
#endif
