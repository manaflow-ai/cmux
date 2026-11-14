import AppKit
@testable import CmuxNextSidebar
import CmuxNextTestSupport
import Foundation
import Testing

/// HOVER COMMIT 2: what VoiceOver sees of a row's hover controls now that a hover clears them by paint (opacity 0,
/// still in the view tree; #37145) instead of hiding them. A cleared control must answer accessibility as a hidden one
/// did: it leaves the row's accessibility children, it is no accessibility hit, and the row tells accessibility when a
/// control clears or shows. Only the hover controls leave: a content control that the shown controls cover (the
/// speaker) stays in the row's children, as it did before #37145.
@MainActor @Suite(.serialized, .closesItsWindows)
struct SidebarHoverAccessibilityTests {
    /// Two closable rows with a menu, one above the other, laid out in a window; `audio` makes both play sound.
    /// `onScreen`: the window is ordered in (an accessibility hit test reads screen frames).
    private func rows(audio: SidebarWorkspaceAudio? = nil, onScreen: Bool = false) -> (WorkspaceRowView, WorkspaceRowView, NSWindow) {
        let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 220, height: 56), styleMask: .borderless,
                              backing: .buffered, defer: !onScreen)
        // `close()` would release a window the test still holds (a segfault on the fleet).
        window.isReleasedWhenClosed = false
        func make(_ id: String, y: CGFloat) -> WorkspaceRowView {
            var ws = SidebarWorkspace(id: WorkspaceID(id), title: "Workspace \(id)", lastActivity: Date())
            ws.audio = audio
            let content = SidebarLayoutOptions().rowContent(ws, machine: nil)
            let row = SidebarRow(key: .workspace(ws.id), y: y, height: 28, section: .pinned, group: nil, siblingIndex: 0,
                                 parentIndex: nil, isLastInGroup: false, isCollapsed: false, childCount: 0, groupColor: nil,
                                 content: content)
            let view = WorkspaceRowView(key: row.key)
            window.contentView?.addSubview(view)
            view.frame = NSRect(x: 0, y: y, width: 220, height: 28)
            view.configure(ws, row: row, badgeStyle: .corner)
            view.onClose = {}
            view.onMore = {}
            view.onToggleAudio = {}
            view.layoutSubtreeIfNeeded()
            return view
        }
        let rows = (make("a", y: 0), make("b", y: 28), window)
        if onScreen { window.orderFrontRegardless() }
        return rows
    }

    /// The pointer leaves `from` for `to`, then the frame's layout pass runs.
    private func cross(from: WorkspaceRowView, to: WorkspaceRowView, in window: NSWindow) {
        from.isHovered = false
        to.isHovered = true
        window.contentView?.layoutSubtreeIfNeeded()
    }

    /// The view an accessibility element stands for (a control answers through its cell).
    private func view(of element: Any?) -> NSView? { (element as? NSView) ?? (element as? NSCell)?.controlView }

    private func reaches(_ element: Any?, _ control: NSView) -> Bool {
        view(of: element).map { $0 === control || $0.isDescendant(of: control) } ?? false
    }

    /// `control`'s center in screen coordinates, as VoiceOver asks a hit test.
    private func screenCenter(of control: NSView, in row: NSView, window: NSWindow) -> NSPoint {
        window.convertPoint(toScreen: row.convert(NSPoint(x: control.frame.midX, y: control.frame.midY), to: nil))
    }

    @Test func aClearedControlIsNoAccessibilityHit() throws {
        let (a, b, window) = rows(onScreen: true)
        defer { window.close() }
        let root = try #require(window.contentView)
        a.isHovered = true
        root.layoutSubtreeIfNeeded()
        cross(from: a, to: b, in: window)
        let close = try #require(a.closeSlot.made), more = try #require(a.moreSlot.made)
        #expect(!close.isHidden && close.alphaValue == 0 && !more.isHidden && more.alphaValue == 0, "the left row's x and ⋮ are not cleared by paint")
        for control in [close, more] {
            let point = screenCenter(of: control, in: a, window: window)
            let rowHit = a.accessibilityHitTest(point), windowHit = root.accessibilityHitTest(point)
            print("HOVER-COMMIT-2 AX hit over a cleared control: row \(String(describing: rowHit)) content \(String(describing: windowHit))")
            #expect(!reaches(rowHit, control), "the row's accessibility hit test answered a cleared control")
            #expect(!reaches(windowHit, control), "the window's accessibility hit test answered a cleared control")
        }
        // AppKit answers the row itself for a point on any of its controls, the shown x too (fleet steps d791effd and
        // 27165c46, on screen and off): this guards that a cleared control never becomes the hit.
        let shown = try #require(b.closeSlot.made)
        let hit = b.accessibilityHitTest(screenCenter(of: shown, in: b, window: window))
        print("HOVER-COMMIT-2 AX hit over the shown x: \(String(describing: hit))")
    }

    @Test func aCoveredSpeakerStaysAnAccessibilityChild() throws {
        let (a, b, window) = rows(audio: .playing)
        defer { window.close() }
        let root = try #require(window.contentView)
        a.isHovered = true
        root.layoutSubtreeIfNeeded()
        let speaker = try #require(a.audioSlot.made)
        print("HOVER-COMMIT-2 speaker \(speaker.frame) alpha \(speaker.alphaValue) x \(String(describing: a.closeSlot.made?.frame))")
        // The precondition: the hovered row's x and ⋮ cover the speaker (it fades to 0 and takes no click).
        #expect(!speaker.isHidden && speaker.alphaValue == 0, "the shown controls do not cover the speaker in this row")
        let children = a.accessibilityChildren() ?? []
        #expect(children.contains { view(of: $0) === speaker }, "a speaker the hover controls cover left the accessibility tree")
        // The hover controls themselves: the hovered row's are children, the cleared ones of the row left are not.
        cross(from: a, to: b, in: window)
        let cleared = try #require(a.closeSlot.made)
        #expect(!(a.accessibilityChildren() ?? []).contains { view(of: $0) === cleared }, "a cleared x stayed in the accessibility tree")
        #expect((b.accessibilityChildren() ?? []).contains { view(of: $0) === b.closeSlot.made }, "the hovered row's x is no accessibility child")
    }

    @MainActor private final class Posts {
        var all: [(element: Any, notification: NSAccessibility.Notification, elements: [Any])] = []
    }

    @Test func aControlThatClearsOrShowsTellsAccessibility() throws {
        let (a, b, window) = rows()
        defer { window.close() }
        let root = try #require(window.contentView)
        // Both rows make their controls (first show), then the pointer is on b.
        a.isHovered = true
        root.layoutSubtreeIfNeeded()
        cross(from: a, to: b, in: window)
        let posts = Posts()
        for row in [a, b] {
            row.postAccessibility = { element, notification, info in
                posts.all.append((element, notification, info?[.uiElements] as? [Any] ?? []))
            }
        }
        cross(from: b, to: a, in: window)
        print("HOVER-COMMIT-2 posts: \(posts.all.map { "\($0.notification.rawValue) on \(String(describing: $0.element))" })")
        let shownClose = try #require(a.closeSlot.made)
        #expect(posts.all.contains { $0.element as? NSView === a && $0.notification == .layoutChanged && $0.elements.contains { view(of: $0) === shownClose } },
                "the row whose x showed told accessibility nothing")
        #expect(posts.all.contains { $0.element as? NSView === b && $0.notification == .layoutChanged },
                "the row whose x and ⋮ cleared told accessibility nothing")
        // A layout with no control change says nothing.
        posts.all.removeAll()
        a.needsLayout = true
        root.layoutSubtreeIfNeeded()
        #expect(posts.all.isEmpty, "a layout that changed no control posted \(posts.all.count) notifications")
    }
}
