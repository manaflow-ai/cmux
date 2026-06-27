public import AppKit
import Dispatch
import ObjectiveC.runtime

extension NSWindow {
    /// The frame the minimal-mode sidebar titlebar control host occupies in this
    /// window's content coordinates.
    ///
    /// Builds a ``MinimalModeSidebarTitlebarControlsMetrics`` from `defaults` and
    /// asks it for the control frame, supplying the live traffic-light position
    /// (when present) so the host can center on the traffic lights. Faithful lift
    /// of the app-side `minimalModeSidebarTitlebarControlsFrame(in:defaults:)`
    /// free function.
    @MainActor
    public func minimalModeSidebarTitlebarControlsFrame(
        defaults: UserDefaults = .standard
    ) -> NSRect {
        let contentView = self.contentView
        let contentBounds = contentView?.bounds ?? NSRect(
            x: 0,
            y: 0,
            width: frame.width,
            height: frame.height
        )
        let trafficLightFrameInContent = minimalModeTrafficLightFrameInContentCoordinates()
        return MinimalModeSidebarTitlebarControlsMetrics(defaults: defaults).controlsFrame(
            contentBounds: contentBounds,
            contentViewIsFlipped: contentView?.isFlipped ?? false,
            trafficLightFrameInContent: trafficLightFrameInContent,
            visualDownwardAdjustment: trafficLightFrameInContent == nil
                ? 0
                : MinimalModeSidebarTitlebarControlsMetrics.titlebarControlsOpticalYOffset(in: self)
        )
    }

    /// The distance from this window's content-view top edge to the minimal-mode
    /// sidebar titlebar control host, accounting for the content view's
    /// flipped-ness. Falls back to the metrics' ``MinimalModeSidebarTitlebarControlsMetrics/topInset``
    /// when there is no content view. Faithful lift of the app-side
    /// `minimalModeSidebarTitlebarControlsTopInset(in:defaults:)` free function.
    @MainActor
    public func minimalModeSidebarTitlebarControlsTopInset(
        defaults: UserDefaults = .standard
    ) -> CGFloat {
        guard let contentView else {
            return MinimalModeSidebarTitlebarControlsMetrics(defaults: defaults).topInset
        }
        let controlsFrame = minimalModeSidebarTitlebarControlsFrame(defaults: defaults)
        if contentView.isFlipped {
            return controlsFrame.minY - contentView.bounds.minY
        }
        return contentView.bounds.maxY - controlsFrame.maxY
    }

    /// The frame of this window's traffic-light cluster, expressed in
    /// `contentView`'s coordinate space, or `nil` when the close button (and thus
    /// the cluster) is absent. Faithful lift of the app-side
    /// `minimalModeTrafficLightFrameInContentCoordinates(window:contentView:)`
    /// free function; main-thread only.
    public func minimalModeTrafficLightFrameInContentCoordinates(
        contentView: NSView
    ) -> NSRect? {
        dispatchPrecondition(condition: .onQueue(.main))
        guard let closeButton = standardWindowButton(.closeButton),
              let closeButtonSuperview = closeButton.superview else {
            return nil
        }
        return closeButtonSuperview.convert(closeButton.frame, to: contentView)
    }

    /// The traffic-light frame in this window's own content-view coordinates, or
    /// `nil` when there is no content view. Faithful lift of the app-side
    /// private `minimalModeTrafficLightFrameInContentCoordinates(for:)` helper.
    @MainActor
    private func minimalModeTrafficLightFrameInContentCoordinates() -> NSRect? {
        guard let contentView else { return nil }
        return minimalModeTrafficLightFrameInContentCoordinates(contentView: contentView)
    }
}

extension NSWindow {
    // Associated-object key token + opaque pointer key backing the minimal-mode
    // sidebar titlebar controls availability flag. `nonisolated(unsafe)`: an
    // immutable `NSObject` identity used only as an opaque objc-runtime key,
    // reachable from the `nonisolated` availability accessors below (their
    // app-target callers are non-isolated free functions).
    private nonisolated(unsafe) static let minimalModeSidebarTitlebarControlsAvailableToken = NSObject()
    private nonisolated static let minimalModeSidebarTitlebarControlsAvailableKey =
        UnsafeRawPointer(Unmanaged.passUnretained(minimalModeSidebarTitlebarControlsAvailableToken).toOpaque())

    /// Records whether the minimal-mode sidebar titlebar controls are currently
    /// available (mounted/visible) for this window, stored as an NSWindow
    /// associated object. Faithful lift of the app-side
    /// `setMinimalModeSidebarTitlebarControlsAvailable(_:in:)` free function;
    /// optionality now lives at the call site.
    public nonisolated func setMinimalModeSidebarTitlebarControlsAvailable(_ isAvailable: Bool) {
        objc_setAssociatedObject(
            self,
            NSWindow.minimalModeSidebarTitlebarControlsAvailableKey,
            NSNumber(value: isAvailable),
            .OBJC_ASSOCIATION_RETAIN_NONATOMIC
        )
    }

    /// Whether the minimal-mode sidebar titlebar controls are available for this
    /// window. Defaults to `true` when the flag has never been set. Faithful lift
    /// of the app-side `minimalModeSidebarTitlebarControlsAreAvailable(in:)` free
    /// function.
    public nonisolated var minimalModeSidebarTitlebarControlsAreAvailable: Bool {
        guard let value = objc_getAssociatedObject(
            self,
            NSWindow.minimalModeSidebarTitlebarControlsAvailableKey
        ) as? NSNumber else {
            return true
        }
        return value.boolValue
    }
}
