import AppKit
import Testing
@testable import CmuxNextDesign

/// While a chat's tools share its pane's tab row, the pane lays the chat over the strip's row, so
/// a native notice pinned to the chat's top sat under the tabs. Notices pin below
/// `NSView.tabRowCover`, the top of the view the row covers (0 while it does not share the row).
@MainActor
struct PaneTabRowCoverTests {
    private func pinned() -> (view: NSView, notice: NSView) {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let notice = NSView()
        notice.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(notice)
        NSLayoutConstraint.activate([
            notice.topAnchor.constraint(equalTo: view.tabRowCover.bottomAnchor, constant: 8),
            notice.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            notice.widthAnchor.constraint(equalToConstant: 100),
            notice.heightAnchor.constraint(equalToConstant: 20),
        ])
        return (view, notice)
    }

    private func top(_ notice: NSView, in view: NSView) -> CGFloat {
        view.layoutSubtreeIfNeeded()
        return view.isFlipped ? notice.frame.minY : view.bounds.height - notice.frame.maxY
    }

    @Test func aNoticeSitsBelowTheSharedRow() {
        let (view, notice) = pinned()
        #expect(top(notice, in: view) == 8)
        view.setTabRowCover(28)
        #expect(top(notice, in: view) == 36)
        view.setTabRowCover(0)
        #expect(top(notice, in: view) == 8)
    }

    @Test func theCoverIsOneGuide() {
        let view = NSView()
        #expect(view.tabRowCover === view.tabRowCover)
        #expect(view.layoutGuides.count == 1)
    }
}
