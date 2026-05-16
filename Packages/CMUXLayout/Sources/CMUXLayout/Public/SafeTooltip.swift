import AppKit
import SwiftUI

private struct SafeTooltipModifier: ViewModifier {
    let text: String?

    func body(content: Content) -> some View {
        content.background {
            SafeTooltipViewRepresentable(text: text)
                .allowsHitTesting(false)
        }
    }
}

private struct SafeTooltipViewRepresentable: NSViewRepresentable {
    let text: String?

    func makeNSView(context: Context) -> SafeTooltipView {
        let view = SafeTooltipView()
        view.updateTooltip(text)
        return view
    }

    func updateNSView(_ nsView: SafeTooltipView, context: Context) {
        nsView.updateTooltip(text)
    }

    static func dismantleNSView(_ nsView: SafeTooltipView, coordinator: ()) {
        nsView.invalidateTooltip()
    }
}

private final class SafeTooltipView: NSView {
    private var tooltipTag: NSView.ToolTipTag?
    private var registeredBounds: NSRect = .zero
    private var registeredText: String?
    private var tooltipText: String?

    override var isOpaque: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func layout() {
        super.layout()
        refreshTooltipRegistration()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        refreshTooltipRegistration()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            invalidateTooltip()
        } else {
            refreshTooltipRegistration()
        }
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        if superview == nil {
            invalidateTooltip()
        } else {
            refreshTooltipRegistration()
        }
    }

    func updateTooltip(_ text: String?) {
        let normalized = text?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        tooltipText = normalized?.isEmpty == false ? normalized : nil
        refreshTooltipRegistration()
    }

    func invalidateTooltip() {
        if let tooltipTag {
            removeToolTip(tooltipTag)
            self.tooltipTag = nil
        }
        registeredBounds = .zero
        registeredText = nil
    }

    private func refreshTooltipRegistration() {
        guard let tooltipText,
              window != nil,
              superview != nil else {
            invalidateTooltip()
            return
        }

        let nextBounds = bounds.standardized.integral
        guard nextBounds.width > 0, nextBounds.height > 0 else {
            invalidateTooltip()
            return
        }

        if tooltipTag != nil,
           nextBounds == registeredBounds,
           tooltipText == registeredText {
            return
        }

        invalidateTooltip()
        tooltipTag = addToolTip(nextBounds, owner: self, userData: nil)
        registeredBounds = nextBounds
        registeredText = tooltipText
    }

    @objc
    func view(
        _ view: NSView,
        stringForToolTip tag: NSView.ToolTipTag,
        point: NSPoint,
        userData data: UnsafeMutableRawPointer?
    ) -> String {
        tooltipText ?? ""
    }

    deinit {
        invalidateTooltip()
    }
}

public extension View {
    /// Uses an AppKit-backed tooltip host that explicitly unregisters its tooltip
    /// before the view is detached or deallocated.
    func safeHelp(_ text: String?) -> some View {
        modifier(SafeTooltipModifier(text: text))
    }
}
