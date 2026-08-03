public import AppKit

/// Native anchor for a detached popover whose arrow is hidden.
@MainActor
public final class ArrowlessPopoverAnchor: NSView, NSPopoverDelegate {
    public var preferredEdge: NSRectEdge
    public var detachedGap: CGFloat
    public var onPresentationChange: @MainActor (Bool) -> Void

    private var contentViewController: NSViewController
    private var popover: NSPopover?
    private var isPresented = false

    /// Whether the underlying popover is currently visible.
    public var isPopoverShown: Bool { popover?.isShown == true }

    /// Creates an arrowless popover anchor around a native content controller.
    public init(
        isPresented: Bool,
        preferredEdge: NSRectEdge,
        detachedGap: CGFloat,
        contentViewController: NSViewController,
        onPresentationChange: @MainActor @escaping (Bool) -> Void = { _ in }
    ) {
        self.preferredEdge = preferredEdge
        self.detachedGap = detachedGap
        self.contentViewController = contentViewController
        self.onPresentationChange = onPresentationChange
        super.init(frame: .zero)
        setAccessibilityElement(false)
        update(
            isPresented: isPresented,
            preferredEdge: preferredEdge,
            detachedGap: detachedGap,
            contentViewController: contentViewController
        )
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        reconcilePresentation()
    }

    /// Applies presentation and content changes to the native popover.
    public func update(
        isPresented: Bool,
        preferredEdge: NSRectEdge,
        detachedGap: CGFloat,
        contentViewController: NSViewController
    ) {
        self.isPresented = isPresented
        self.preferredEdge = preferredEdge
        self.detachedGap = detachedGap
        self.contentViewController = contentViewController
        if let popover {
            popover.contentViewController = contentViewController
            updateContentSize(of: popover)
        }
        reconcilePresentation()
    }

    /// Presents the popover when the anchor is attached to a window.
    public func present() {
        isPresented = true
        reconcilePresentation()
    }

    /// Closes the popover and publishes the presentation change.
    public func dismiss() {
        isPresented = false
        popover?.performClose(nil)
        if popover == nil { onPresentationChange(false) }
    }

    public func popoverDidClose(_ notification: Notification) {
        popover = nil
        if isPresented {
            isPresented = false
            onPresentationChange(false)
        }
    }

    private func reconcilePresentation() {
        guard isPresented else {
            if popover?.isShown == true { popover?.performClose(nil) }
            return
        }
        guard window != nil else { return }
        let popover = popover ?? makePopover()
        guard !popover.isShown else { return }
        updateContentSize(of: popover)
        popover.show(
            relativeTo: positioningRect(
                for: bounds,
                preferredEdge: preferredEdge,
                detachedGap: detachedGap
            ),
            of: self,
            preferredEdge: preferredEdge
        )
    }

    private func makePopover() -> NSPopover {
        let popover = NSPopover()
        popover.behavior = .semitransient
        popover.animates = true
        popover.setValue(true, forKeyPath: "shouldHideAnchor")
        popover.contentViewController = contentViewController
        popover.delegate = self
        self.popover = popover
        return popover
    }

    private func updateContentSize(of popover: NSPopover) {
        let view = contentViewController.view
        view.invalidateIntrinsicContentSize()
        view.layoutSubtreeIfNeeded()
        let fittingSize = view.fittingSize
        guard fittingSize.width > 0, fittingSize.height > 0 else { return }
        CmuxPopoverMutation.setContentSize(
            NSSize(width: ceil(fittingSize.width), height: ceil(fittingSize.height)),
            on: popover
        )
    }

    private func positioningRect(
        for bounds: CGRect,
        preferredEdge: NSRectEdge,
        detachedGap: CGFloat
    ) -> CGRect {
        let hiddenArrowInset: CGFloat = 13
        let compensation = max(hiddenArrowInset - detachedGap, 0)

        return switch preferredEdge {
        case .maxY:
            NSRect(
                x: bounds.minX,
                y: bounds.maxY - compensation,
                width: bounds.width,
                height: compensation
            )
        case .minY:
            NSRect(
                x: bounds.minX,
                y: bounds.minY,
                width: bounds.width,
                height: compensation
            )
        case .maxX:
            NSRect(
                x: bounds.maxX - compensation,
                y: bounds.minY,
                width: compensation,
                height: bounds.height
            )
        case .minX:
            NSRect(
                x: bounds.minX,
                y: bounds.minY,
                width: compensation,
                height: bounds.height
            )
        @unknown default:
            bounds
        }
    }
}
