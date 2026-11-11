public import AppKit

/// The native New Tab page in a pane tab: the AppKit ``NativeNewTabView``, plus the field the pane
/// gives the keyboard to (a focused pane makes ``fieldView`` first responder, as it does a web
/// page's field), so the keys typed after Cmd-T land in the field.
public final class NativeNewTabHostingView: NSView {
    /// The page's model: a prepared page adopts a tab's context through it.
    public let model: NativeNewTabModel?
    /// The page.
    public let page: NativeNewTabView

    /// The page's text field. AppKit makes it with the page, so it exists before the first layout.
    public var fieldView: NSView? { page.fieldView }

    /// Runs once, at the first layout in a window: the host sends the keys typed since Cmd-T to the
    /// field (the New Tab input hold).
    public var onFieldReady: (@MainActor () -> Void)?

    /// The page over `model`, filling the view.
    /// - Parameter model: The page's state.
    public init(model: NativeNewTabModel) {
        self.model = model
        page = NativeNewTabView(model: model)
        super.init(frame: page.frame)
        page.frame = bounds
        page.autoresizingMask = [.width, .height]
        addSubview(page)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Joining a window lays the page out in that window's next layout pass, where ``onFieldReady`` runs.
    override public func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { needsLayout = true }
    }

    /// The pane focused this view before it was laid out: the field takes the keyboard, and
    /// ``onFieldReady`` runs.
    override public func layout() {
        super.layout()
        guard let window else { return }
        if window.firstResponder === self { window.makeFirstResponder(page.fieldView) }
        if let ready = onFieldReady {
            onFieldReady = nil
            ready()
        }
    }
}
