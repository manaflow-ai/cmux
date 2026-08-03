public import AppKit

/// Native reader for the leading inset occupied by traffic lights and titlebar accessories.
@MainActor
public final class TitlebarLeadingInsetReader: NSView {
    public var baseLeadingInset: @MainActor () -> CGFloat
    public var onInsetChange: @MainActor (CGFloat) -> Void
    private var lastInset: CGFloat?

    /// Creates a titlebar inset reader.
    public init(
        baseLeadingInset: @MainActor @escaping () -> CGFloat,
        onInsetChange: @MainActor @escaping (CGFloat) -> Void
    ) {
        self.baseLeadingInset = baseLeadingInset
        self.onInsetChange = onInsetChange
        super.init(frame: .zero)
        setFrameSize(.zero)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public override var mouseDownCanMoveWindow: Bool { false }
    public override func hitTest(_ point: NSPoint) -> NSView? { nil }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        resolveInset()
    }

    public override func layout() {
        super.layout()
        resolveInset()
    }

    /// Recomputes and reports the current inset when it changed.
    public func resolveInset() {
        guard let window else { return }
        var leading = baseLeadingInset()
        for accessory in window.titlebarAccessoryViewControllers
            where accessory.layoutAttribute == .leading || accessory.layoutAttribute == .left {
            leading += accessory.view.frame.width
        }
        guard leading != lastInset else { return }
        lastInset = leading
        onInsetChange(leading)
    }
}
