public import AppKit
public import SwiftUI

/// Reads the leading inset required to clear traffic lights and titlebar accessories.
public struct TitlebarLeadingInsetReader: NSViewRepresentable {
    @Binding private var inset: CGFloat
    private let baseLeadingInset: @MainActor () -> CGFloat

    /// Creates a titlebar leading inset reader.
    public init(
        inset: Binding<CGFloat>,
        baseLeadingInset: @escaping @MainActor () -> CGFloat
    ) {
        _inset = inset
        self.baseLeadingInset = baseLeadingInset
    }

    /// Creates the passthrough AppKit reader view.
    public func makeNSView(context: Context) -> NSView {
        let view = TitlebarLeadingInsetPassthroughView()
        view.setFrameSize(.zero)
        return view
    }

    /// Updates the SwiftUI binding with the current leading inset.
    public func updateNSView(_ nsView: NSView, context: Context) {
        Task { @MainActor in
            guard let window = nsView.window else { return }
            var leading = baseLeadingInset()
            for accessory in window.titlebarAccessoryViewControllers
                where accessory.layoutAttribute == .leading || accessory.layoutAttribute == .left {
                leading += accessory.view.frame.width
            }
            if leading != inset {
                inset = leading
            }
        }
    }
}

final class TitlebarLeadingInsetPassthroughView: NSView {
    override var mouseDownCanMoveWindow: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
