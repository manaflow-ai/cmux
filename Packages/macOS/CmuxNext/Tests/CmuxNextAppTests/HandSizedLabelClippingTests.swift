import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextHome
@testable import CmuxNextSidebar
@testable import CmuxNextTabs
import CmuxNextTestSupport
import Foundation
import Testing

/// A label a view frames by hand holds its whole text (user 2026-10-27, "file slightly cut off
/// here"). A label's `intrinsicContentSize` is its text alone, in alignment-rect terms; the text
/// draws 2 pt inside the frame, so a frame that size cut the last glyph or truncated the text
/// ("Running" became "Runn…", a count lost its digit's edge). Each view here has room for its
/// text, so every shown label's frame must hold its text and its padding.
@MainActor @Suite(.serialized, .closesItsWindows) struct HandSizedLabelClippingTests {
    /// The labels under `root` whose frames are narrower than their text and padding, as
    /// "text: frame width < needed width".
    private static func clipped(in root: NSView) -> [String] {
        root.layoutSubtreeIfNeeded()
        var found: [String] = []
        func visit(_ view: NSView) {
            guard !view.isHidden else { return }
            if let label = view as? ChromeLabel, !label.stringValue.isEmpty {
                let needed = label.naturalSize.width
                if label.frame.width + 0.5 < needed {
                    found.append("\"\(label.stringValue)\": \(label.frame.width) < \(needed)")
                }
            } else if let field = view as? NSTextField, !field.isEditable, !field.stringValue.isEmpty,
                      let needed = field.cell?.cellSize.width {
                if field.frame.width + 0.5 < needed {
                    found.append("\"\(field.stringValue)\": \(field.frame.width) < \(needed)")
                }
            }
            view.subviews.forEach(visit)
        }
        visit(root)
        return found
    }

    private static func host(_ view: NSView, size: NSSize) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: NSSize(width: size.width + 40, height: size.height + 40)),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        view.frame = NSRect(origin: NSPoint(x: 20, y: 20), size: size)
        window.contentView!.addSubview(view)
        view.layoutSubtreeIfNeeded()
        return window
    }

    @Test(arguments: SidebarStatusSection.allCases)
    func statusHeaderShowsItsWholeNameAndCount(_ section: SidebarStatusSection) {
        let view = StatusHeaderRowView(key: .status(section))
        view.configure(SidebarRow(key: .status(section), y: 0, height: 28, section: .pinned, siblingIndex: 0,
                                  isLastInGroup: true, isCollapsed: false, childCount: 128))
        let window = Self.host(view, size: NSSize(width: 280, height: 28))
        defer { window.closeAfterTest() }
        #expect(Self.clipped(in: view) == [])
        _ = window
    }

    @Test func presenceOverflowCountIsWhole() {
        let view = PresenceDotsView()
        view.configure((0..<9).map { SidebarPresence(id: "a\($0)", name: "Agent \($0)", activity: .running) })
        let window = Self.host(view, size: NSSize(width: view.preferredWidth, height: 16))
        defer { window.closeAfterTest() }
        #expect(Self.clipped(in: view) == [])
        _ = window
    }

    @Test func rollUpCountsAreWhole() {
        let view = SidebarTreeRollUpView()
        view.configure(SidebarTreeRollUp(blocked: 3, failed: 12, running: 108, unread: 7))
        let window = Self.host(view, size: view.intrinsicContentSize)
        defer { window.closeAfterTest() }
        #expect(Self.clipped(in: view) == [])
        _ = window
    }

    @Test func pullRequestBadgeCountIsWhole() {
        let view = SidebarPullRequestBadgeView()
        view.configure(SidebarPullRequestBadge(count: 12, status: .passing))
        let window = Self.host(view, size: view.intrinsicContentSize)
        defer { window.closeAfterTest() }
        #expect(Self.clipped(in: view) == [])
        _ = window
    }

    @Test func historyRowMetaIsWhole() {
        let view = SidebarChatHistoryRow()
        view.configure(title: "Fix the omnibar", meta: "12m", quiet: false)
        let window = Self.host(view, size: NSSize(width: 280, height: 28))
        defer { window.closeAfterTest() }
        #expect(Self.clipped(in: view) == [])
        _ = window
    }

    @Test func recipientChipAndToLabelAreWhole() {
        let chip = HomeRecipientChip(token: HomeRecipientToken(text: "Lawrence Chen", recipient: nil))
        let window = Self.host(chip, size: NSSize(width: chip.preferredWidth, height: HomeRecipientChip.height))
        defer { window.closeAfterTest() }
        #expect(Self.clipped(in: chip) == [])
        let field = HomeRecipientField(frame: NSRect(x: 0, y: 0, width: 480, height: 44))
        let fieldWindow = Self.host(field, size: NSSize(width: 480, height: 44))
        defer { fieldWindow.closeAfterTest() }
        #expect(Self.clipped(in: field) == [])
        _ = (window, fieldWindow)
    }

    @Test func linkDragGhostTitleIsWhole() throws {
        let ghost = LinkDragGhost(title: "Pull request: fix the omnibar")
        defer { ghost.close() }
        let root = try #require(ghost.panel.contentView)
        #expect(Self.clipped(in: root) == [])
    }
}
