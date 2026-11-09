public import AppKit
public import CmuxNextDesign

/// Shows the plan picker (``CloudPlanPicker``) over a whole window and answers the person's pick: a plan to check
/// out, Run on This Mac, or nil for Not Now, Escape or the window closing. It is the window's modal overlay (the
/// dialog layer, like Share cmux): the window behind is blocked, the keyboard stays in the picker, and it follows
/// the window's size and theme.
///
/// ```swift
/// let choice = await CloudPlanPickerPresenter().choose(CloudPlanPicker(offersRunHere: true), in: window)
/// ```
@MainActor
public struct CloudPlanPickerPresenter {
    public init() {}

    /// The picker waiting for the person over `window`, if any: one at a time. Read from the window's overlay
    /// panel, so no state outlives the picker (a closing one that already answered does not count).
    public func shown(in window: NSWindow) -> CloudPlanPickerHostingView? {
        guard let root = WindowOverlayHost.existingHost(for: window)?.panel.contentView else { return nil }
        var views: [NSView] = [root]
        while let view = views.popLast() {
            if let picker = view as? CloudPlanPickerHostingView, picker.isWaiting { return picker }
            views.append(contentsOf: view.subviews)
        }
        return nil
    }

    /// Shows `picker` filling `window` and waits for the person. Nil at once when there is no window or a picker
    /// already shows.
    public func choose(_ picker: CloudPlanPicker, in window: NSWindow?) async -> CloudPlanPicker.Choice? {
        guard let window, shown(in: window) == nil else { return nil }
        return await withCheckedContinuation { continuation in
            let host = WindowOverlayHost.host(for: window)
            let view = CloudPlanPickerHostingView(picker: picker)
            view.setFrameSize(Self.size(of: window))
            let handle = host.present(view, options: .dialog(dimsContent: false))
            // The view answers once (``CloudPlanPickerHostingView/answer`` is cleared on its first call).
            view.answer = { [weak handle] choice in
                continuation.resume(returning: choice)
                handle?.dismiss()
            }
            // Escape (the overlay's own dismissal) and a closed window answer nil.
            handle.onDismiss = { [weak view] in view?.notNow() }
            handle.onWindowGeometryChange = { [weak view, weak window, weak handle] in
                guard let view, let window else { return }
                view.setFrameSize(Self.size(of: window))
                handle?.update(anchor: NSRect(origin: .zero, size: view.frame.size))
            }
        }
    }

    /// The whole content area of `window`.
    static func size(of window: NSWindow) -> NSSize { window.contentView?.bounds.size ?? window.contentLayoutRect.size }
}
