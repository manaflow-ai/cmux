public import AppKit
public import CmuxNextDesign
import SwiftUI

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
            let view = CloudPlanPickerHostingView(picker: picker, tokens: { [weak window] in window?.contentView?.themeScope.tokens ?? ThemeScope.app.tokens })
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

/// The picker's AppKit view: a container around the SwiftUI page that draws it in its window's theme again on each
/// appearance change (``ThemeScope`` is not observable).
@MainActor
public final class CloudPlanPickerHostingView: NSView {
    /// The person's pick (the presenter's), once.
    var answer: (@MainActor (CloudPlanPicker.Choice?) -> Void)?
    private let picker: CloudPlanPicker
    private let tokens: @MainActor () -> ThemeTokens
    private var palette: CloudPlanPickerPalette
    private let hosting: NSHostingView<AnyView>

    init(picker: CloudPlanPicker, tokens: @escaping @MainActor () -> ThemeTokens) {
        self.picker = picker
        self.tokens = tokens
        let palette = CloudPlanPickerPalette(tokens: tokens())
        self.palette = palette
        hosting = NSHostingView(rootView: AnyView(EmptyView()))
        super.init(frame: .zero)
        identifier = NSUserInterfaceItemIdentifier("cmux.cloud.planPicker")
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilitySubrole(.dialog)
        setAccessibilityLabel(CloudPlanPickerStrings.title)
        setAccessibilityModal(true)
        hosting.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: leadingAnchor), hosting.trailingAnchor.constraint(equalTo: trailingAnchor),
            hosting.topAnchor.constraint(equalTo: topAnchor), hosting.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        render()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    /// The picker still waits for the person's pick.
    public var isWaiting: Bool { answer != nil }

    /// Picks `choice` as a click on its button does (a plan's Get button, Run on This Mac).
    public func choose(_ choice: CloudPlanPicker.Choice) { take()?(choice) }

    /// Not Now: no plan, nothing created.
    public func notNow() { take()?(nil) }

    /// The answer, cleared: the person's first pick is the only one.
    private func take() -> (@MainActor (CloudPlanPicker.Choice?) -> Void)? {
        defer { answer = nil }
        return answer
    }

    public override func cancelOperation(_ sender: Any?) { notNow() }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        let next = CloudPlanPickerPalette(tokens: tokens())
        guard next != palette else { return }
        palette = next
        render()
    }

    private func render() {
        let actions = CloudPlanPickerView.Actions(choose: { [weak self] in self?.choose($0) }, notNow: { [weak self] in self?.notNow() })
        hosting.rootView = AnyView(CloudPlanPickerView(picker: picker, palette: palette, actions: actions))
    }
}
