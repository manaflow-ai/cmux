public import AppKit

/// The AppKit host of one mounted scene (a sidebar section, a Session Info section, an app pane): an
/// `NSView` plus a height for a width. The scene draws in AppKit (``AppSceneNativeView``, with the
/// sidebar's own row tokens and the theme), whatever nodes it uses.
public final class AppSceneHostingView: NSView {
    public let model: AppSceneModel
    /// Runs when the content's height may have changed (a new scene, a status change).
    public var onContentSizeChange: (() -> Void)?
    private let native: AppSceneNativeView

    /// - Parameters:
    ///   - model: The mount's scene.
    ///   - bundleDirectory: The app bundle's folder, where `Image` nodes read their files.
    public init(model: AppSceneModel, bundleDirectory: URL?) {
        self.model = model
        native = AppSceneNativeView(model: model, bundleDirectory: bundleDirectory)
        super.init(frame: .zero)
        native.onContentSizeChange = { [weak self] in
            self?.invalidateIntrinsicContentSize()
            self?.onContentSizeChange?()
        }
        native.autoresizingMask = [.width, .height]
        addSubview(native)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public nonisolated override var isFlipped: Bool { true }

    /// Brings a scene change applied in this main-actor turn onto the screen now (a host that lays
    /// out right after applying ops, before the observation's next turn).
    public override func layoutSubtreeIfNeeded() {
        native.redrawIfNeeded()
        super.layoutSubtreeIfNeeded()
    }

    public override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: preferredHeight(width: bounds.width))
    }

    /// The scene's height when laid out `width` points wide.
    public func preferredHeight(width: CGFloat) -> CGFloat { native.preferredHeight(width: width) }

    public override func layout() {
        super.layout()
        native.frame = bounds
    }
}
