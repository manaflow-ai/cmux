import AppKit
import SwiftUI

/// Hosts the native trailing title-bar cluster and reports its live AppKit layout width.
@MainActor
final class TitlebarTrailingAccessoryHostingView: NSHostingView<TitlebarTrailingControls> {
    var onMeasuredWidthChange: ((CGFloat) -> Void)?

    private var lastReportedWidth: CGFloat = 0

    override func layout() {
        super.layout()
        reportCurrentWidth()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        reportCurrentWidth()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil {
            report(width: 0, force: true)
        }
        super.viewWillMove(toWindow: newWindow)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            reportCurrentWidth(force: true)
        }
    }

    override func viewDidHide() {
        super.viewDidHide()
        report(width: 0, force: true)
    }

    override func viewDidUnhide() {
        super.viewDidUnhide()
        reportCurrentWidth(force: true)
    }

    func reportCurrentWidth(force: Bool = false) {
        let intrinsicWidth = super.intrinsicContentSize.width
        let width = intrinsicWidth.isFinite && intrinsicWidth > 0
            ? intrinsicWidth
            : fittingSize.width
        report(width: width, force: force)
    }

    private func report(width rawWidth: CGFloat, force: Bool = false) {
        let width = rawWidth.isFinite ? max(0, rawWidth) : 0
        guard force || abs(width - lastReportedWidth) > 0.5 else { return }
        lastReportedWidth = width
        onMeasuredWidthChange?(width)
    }
}
