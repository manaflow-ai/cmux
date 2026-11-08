public import AppKit
import CmuxNextCompat
import SwiftUI

/// The AppKit host of one mounted scene (a sidebar section, a hover card): it wants an `NSView` plus a
/// height for a width. A scene built from the kit's list pieces draws in AppKit (``AppSceneNativeView``,
/// the sidebar's own row tokens); a scene with a control the AppKit renderer does not draw yet keeps
/// the SwiftUI renderer (``AppSceneView``) in a hosting view below this one. The choice follows the
/// scene as it changes.
public final class AppSceneHostingView: NSView {
    public let model: AppSceneModel
    /// Runs when the content's height may have changed (a new scene, a SwiftUI size change).
    public var onContentSizeChange: (() -> Void)?
    private let bundleDirectory: URL?
    private let useSidebarBackground: Bool
    private var native: AppSceneNativeView?
    private var fallback: FallbackHostingView?

    public init(model: AppSceneModel, bundleDirectory: URL?, useSidebarBackground: Bool = true) {
        self.model = model
        self.bundleDirectory = bundleDirectory
        self.useSidebarBackground = useSidebarBackground
        super.init(frame: .zero)
        choose()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public nonisolated override var isFlipped: Bool { true }

    /// Whether the scene draws in AppKit now (false: the SwiftUI fallback).
    var drawsNatively: Bool { native != nil }

    /// The task that switches renderer when the scene starts or stops needing the fallback.
    private var feed: Task<Void, Never>?

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        feed?.cancel()
        feed = nil
        guard window != nil else { return }
        choose()
        // task-owner: this view (cancelled when it leaves its window); event-driven (Observation).
        feed = Task { [weak self, model] in
            for await _ in ObservationStream({ model.scene.isNativelyRenderable }) { self?.choose() }
        }
    }

    /// Brings a scene change applied in this main-actor turn onto the screen now (a host that lays
    /// out right after applying ops, before the observation's next turn).
    public override func layoutSubtreeIfNeeded() {
        choose()
        native?.redrawIfNeeded()
        super.layoutSubtreeIfNeeded()
    }

    /// Puts the renderer the scene needs in place (no-op when it already is).
    private func choose() {
        if model.scene.isNativelyRenderable {
            guard native == nil else { return }
            fallback?.removeFromSuperview()
            fallback = nil
            let view = AppSceneNativeView(model: model)
            view.onContentSizeChange = { [weak self] in self?.contentSizeChanged() }
            native = view
            add(view)
        } else {
            guard fallback == nil else { return }
            native?.removeFromSuperview()
            native = nil
            let view = FallbackHostingView(model: model, bundleDirectory: bundleDirectory, useSidebarBackground: useSidebarBackground)
            view.onSizeChange = { [weak self] in self?.contentSizeChanged() }
            fallback = view
            add(view)
        }
        contentSizeChanged()
    }

    private func add(_ view: NSView) {
        view.frame = bounds
        view.autoresizingMask = [.width, .height]
        addSubview(view)
    }

    private func contentSizeChanged() {
        invalidateIntrinsicContentSize()
        onContentSizeChange?()
    }

    public override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: preferredHeight(width: bounds.width))
    }

    /// The scene's height when laid out `width` points wide.
    public func preferredHeight(width: CGFloat) -> CGFloat {
        if let native { return native.preferredHeight(width: width) }
        return fallback?.preferredHeight(width: width) ?? 0
    }

    public override func layout() {
        super.layout()
        for view in subviews { view.frame = bounds }
    }
}

/// The SwiftUI renderer in a hosting view, themed from its AppKit scope, for scenes the AppKit
/// renderer does not draw yet.
private final class FallbackHostingView: NSHostingView<AnyView> {
    private let sceneAppearance: AppSceneAppearance
    /// Measures heights for a width without laying out this view.
    private let measurer: NSHostingController<AnyView>
    var onSizeChange: (() -> Void)?

    init(model: AppSceneModel, bundleDirectory: URL?, useSidebarBackground: Bool) {
        let appearance = AppSceneAppearance(useSidebarBackground: useSidebarBackground)
        sceneAppearance = appearance
        let root = AnyView(AppSceneThemedRoot(appearance: appearance) { AppSceneView(model: model, bundleDirectory: bundleDirectory) })
        measurer = NSHostingController(rootView: root)
        super.init(rootView: root)
        sizingOptions = [.intrinsicContentSize]
    }

    @available(*, unavailable)
    @MainActor required init(rootView: AnyView) { fatalError("init(rootView:) is not supported") }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        sceneAppearance.update(from: self)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        sceneAppearance.update(from: self)
    }

    override func invalidateIntrinsicContentSize() {
        super.invalidateIntrinsicContentSize()
        onSizeChange?()
    }

    func preferredHeight(width: CGFloat) -> CGFloat {
        ceil(measurer.sizeThatFits(in: NSSize(width: width, height: .greatestFiniteMagnitude)).height)
    }
}
