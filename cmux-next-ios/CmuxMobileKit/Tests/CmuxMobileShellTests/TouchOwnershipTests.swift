import CoreGraphics
import Testing
@testable import CmuxMobileDesign

/// Leo, 2026-11-23: a drag must go to the view it started on (design/gesture-matrix.md). The pure
/// half of `TouchOwnership`: when a sideways scroller still takes a drag, and which way the
/// leading drawer opens.
@Suite struct TouchOwnershipTests {
    @Test func aScrollerInTheMiddleTakesBothWays() {
        #expect(TouchOwnership.scrollerTakes(fingerDX: -10, offsetX: 50, contentWidth: 600, boundsWidth: 300))
        #expect(TouchOwnership.scrollerTakes(fingerDX: 10, offsetX: 50, contentWidth: 600, boundsWidth: 300))
    }

    @Test func aScrollerAtItsStartLeavesARightwardDragToItsContainer() {
        #expect(!TouchOwnership.scrollerTakes(fingerDX: 10, offsetX: 0, contentWidth: 600, boundsWidth: 300))
        #expect(TouchOwnership.scrollerTakes(fingerDX: -10, offsetX: 0, contentWidth: 600, boundsWidth: 300))
    }

    @Test func aScrollerAtItsEndLeavesALeftwardDragToItsContainer() {
        // The row's trailing swipe actions come out once the code is scrolled to its end.
        #expect(!TouchOwnership.scrollerTakes(fingerDX: -10, offsetX: 300, contentWidth: 600, boundsWidth: 300))
        #expect(TouchOwnership.scrollerTakes(fingerDX: 10, offsetX: 300, contentWidth: 600, boundsWidth: 300))
    }

    @Test func insetsCountAsScrollableRoom() {
        #expect(TouchOwnership.scrollerTakes(fingerDX: 10, offsetX: 0, contentWidth: 600, boundsWidth: 300, insetLeft: 16))
        #expect(!TouchOwnership.scrollerTakes(fingerDX: 10, offsetX: -16, contentWidth: 600, boundsWidth: 300, insetLeft: 16))
    }

    @Test func contentThatFitsNeverTakesASidewaysDrag() {
        #expect(!TouchOwnership.scrollerTakes(fingerDX: -10, offsetX: 0, contentWidth: 300, boundsWidth: 300))
        #expect(!TouchOwnership.scrollerTakes(fingerDX: 0, offsetX: 0, contentWidth: 300.5, boundsWidth: 300))
    }

    @Test func theDrawerOpensAwayFromTheLeadingEdge() {
        #expect(TouchOwnership.fromLeading(40, rightToLeft: false) == 40)
        #expect(TouchOwnership.fromLeading(40, rightToLeft: true) == -40, "a rightward drag in RTL is a row's trailing swipe")
        #expect(TouchOwnership.fromLeading(-40, rightToLeft: true) == 40)
    }
}

#if os(iOS)
import UIKit
@testable import CmuxMobileFeed
@testable import CmuxMobileShell

@MainActor @Suite(.serialized) struct TouchOwnershipViewTests {
    @Test func aWideScrollerOwnsItsSidewaysDragUntilItsEnd() {
        let root = UIView(frame: CGRect(x: 0, y: 0, width: 400, height: 400))
        let scroll = UIScrollView(frame: CGRect(x: 0, y: 0, width: 300, height: 100))
        scroll.contentSize = CGSize(width: 900, height: 100)
        let code = UIView(frame: CGRect(x: 0, y: 0, width: 900, height: 100))
        scroll.addSubview(code)
        root.addSubview(scroll)
        #expect(TouchOwnership.wideScroller(from: code, upTo: root) === scroll)
        #expect(TouchOwnership.ownsHorizontalDrag(from: code, upTo: root, fingerDX: -20))
        #expect(!TouchOwnership.ownsHorizontalDrag(from: code, upTo: root, fingerDX: 20), "at its start: the container's")
        #expect(!TouchOwnership.ownsHorizontalDrag(from: root, upTo: root, fingerDX: -20))
    }

    @Test func controlsAndEditableTextOwnTheirTap() {
        let root = UIView()
        let button = UIButton(type: .system)
        let icon = UIView()
        button.addSubview(icon)
        let label = UILabel()
        let text = UITextView()
        let readOnly = UITextView()
        readOnly.isEditable = false
        for view in [button, label, text, readOnly] { root.addSubview(view) }
        #expect(TouchOwnership.isControlOrTextInput(from: icon, upTo: root), "a button's icon is the button's")
        #expect(TouchOwnership.isControlOrTextInput(from: text, upTo: root))
        #expect(!TouchOwnership.isControlOrTextInput(from: label, upTo: root))
        #expect(!TouchOwnership.isControlOrTextInput(from: readOnly, upTo: root))
        button.isEnabled = false
        #expect(!TouchOwnership.isControlOrTextInput(from: icon, upTo: root), "a disabled button leaves the row its tap")
    }

    /// Cell 38: the Feed row's open and header taps leave a field or control its touch.
    @Test func feedRowTapsLeaveControlsTheirTouch() {
        let cell = UIView()
        let row = UIView()
        cell.addSubview(row)
        let field = UITextField()
        let send = UIButton(type: .custom)
        let body = UIView()
        for view in [field, send, body] { row.addSubview(view) }
        #expect(!FeedRowCell.rowTapMayBegin(on: field, in: row))
        #expect(!FeedRowCell.rowTapMayBegin(on: send, in: row))
        #expect(FeedRowCell.rowTapMayBegin(on: body, in: row))
    }

    /// Cell 45: the drawer runs alongside only a scroller the touch is in.
    @Test func theDrawerRunsAlongsideOnlyTheTouchedScroller() {
        let root = UIView()
        let touchedList = UIScrollView()
        let row = UIView()
        touchedList.addSubview(row)
        let otherList = UIScrollView()
        root.addSubview(touchedList)
        root.addSubview(otherList)
        #expect(SidebarContainerViewController.isUnderTouch(touchedList, touched: row))
        #expect(!SidebarContainerViewController.isUnderTouch(otherList, touched: row))
        #expect(!SidebarContainerViewController.isUnderTouch(touchedList, touched: nil))
    }

    /// Cell 44: a sideways drag on a field being edited moves its caret; the drawer stays shut.
    @Test func theDrawerStaysShutForADragOnTextBeingEdited() {
        let content = UIViewController()
        let field = UITextField(frame: CGRect(x: 20, y: 120, width: 360, height: 44))
        content.view.addSubview(field)
        let drawer = SidebarContainerViewController(model: SidebarModel(), sidebar: UIViewController(), content: content)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        window.rootViewController = drawer
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        drawer.view.layoutIfNeeded()
        RowSwipeActions.shared.closeAll()
        #expect(drawer.mayOpen(at: CGPoint(x: 200, y: 142)), "not editing: the drawer may open from the field")
        field.becomeFirstResponder()
        if field.isFirstResponder {
            #expect(!drawer.mayOpen(at: CGPoint(x: 200, y: 142)), "editing: the drag is the caret's")
            #expect(drawer.mayOpen(at: CGPoint(x: 200, y: 600)), "elsewhere the drawer still opens")
        }
        field.resignFirstResponder()
    }
}
#endif
