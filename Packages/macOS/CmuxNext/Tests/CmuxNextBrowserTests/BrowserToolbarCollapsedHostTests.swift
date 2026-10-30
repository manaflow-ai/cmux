import AppKit
@testable import CmuxNextBrowser
import CmuxNextDesign
import Testing

/// A pane's content host is 0 points high for a moment while a workspace or its tabs are restored;
/// the browser chrome inside it (autoresizing, as `PaneContentView.install` puts it) cannot fit its
/// toolbar rows then. Its rows must keep their edge: before, every vertical pin was required, AppKit
/// broke one of its own choosing, and when that was the toolbar's top pin the omnibar came back at
/// the bottom of the pane with `browser.toolbarPosition` top (user report, 2026-10-29). Rects are in
/// window coordinates (y up). Which pin AppKit breaks is its own choice, so the tests also count the
/// conflicts it reports (`ConflictRecordingWindow`): there must be none.
@MainActor @Suite(.serialized) struct BrowserToolbarCollapsedHostTests {
    struct Hosted {
        let window: ConflictRecordingWindow
        let host: NSView
        let chrome: BrowserChromeView
        let page: WebKitTab

        init(position: ToolbarPosition) {
            window = ConflictRecordingWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600), styleMask: [.titled],
                                             backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            let root = NSView(frame: window.contentLayoutRect)
            window.contentView = root
            host = NSView(frame: root.bounds)
            host.autoresizingMask = [.width, .height]
            root.addSubview(host)
            page = WebKitEngine(fileInput: NoFileInput(), stores: .inMemory()).makeWebKitTab()
            chrome = BrowserChromeView(tab: page)
            chrome.toolbarPosition = position
            chrome.frame = host.bounds
            chrome.autoresizingMask = [.width, .height]
            host.addSubview(chrome)
            window.orderFrontRegardless()
            root.layoutSubtreeIfNeeded()
        }

        /// The host collapses to 0 points high and lays out, then grows back and lays out.
        func collapseAndRestore() -> (collapsed: NSRect, collapsedChrome: NSRect) {
            let full = host.frame
            host.frame.size.height = 0
            window.contentView?.layoutSubtreeIfNeeded()
            let collapsed = (rect(chrome.toolbar), rect(chrome))
            host.frame = full
            window.contentView?.layoutSubtreeIfNeeded()
            return collapsed
        }

        func rect(_ view: NSView) -> NSRect { view.convert(view.bounds, to: nil) }

        func tearDown() {
            window.orderOut(nil)
            window.close()
            page.close()
        }
    }

    @Test func aTopToolbarKeepsTheTopThroughACollapsedHost() {
        let view = Hosted(position: .top)
        defer { view.tearDown() }
        let height = view.chrome.toolbarHeight.constant
        let collapsed = view.collapseAndRestore()
        #expect(view.window.verticalConflicts.isEmpty, "AppKit broke a vertical pin: \(view.window.verticalConflicts)")
        #expect(collapsed.collapsed.height == height, "the toolbar row keeps its height while the host is 0 high")
        #expect(collapsed.collapsed.maxY == collapsed.collapsedChrome.maxY, "pinned to the chrome's top while collapsed")
        let toolbar = view.rect(view.chrome.toolbar), page = view.rect(view.chrome.contentContainer), all = view.rect(view.chrome)
        #expect(toolbar.height == height)
        #expect(toolbar.maxY == all.maxY, "the omnibar row is back at the top")
        #expect(page.minY == all.minY, "the page fills to the bottom again")
        #expect(page.maxY <= toolbar.minY)
    }

    @Test func aBottomToolbarKeepsTheBottomThroughACollapsedHost() {
        let view = Hosted(position: .bottom)
        defer { view.tearDown() }
        let height = view.chrome.toolbarHeight.constant
        let collapsed = view.collapseAndRestore()
        #expect(view.window.verticalConflicts.isEmpty, "AppKit broke a vertical pin: \(view.window.verticalConflicts)")
        #expect(collapsed.collapsed.height == height)
        #expect(collapsed.collapsed.minY == collapsed.collapsedChrome.minY, "pinned to the chrome's bottom while collapsed")
        let toolbar = view.rect(view.chrome.toolbar), page = view.rect(view.chrome.contentContainer), all = view.rect(view.chrome)
        #expect(toolbar.height == height)
        #expect(toolbar.minY == all.minY, "the omnibar row is back at the bottom")
        #expect(page.maxY == all.maxY, "the page fills to the top again")
        #expect(page.minY >= toolbar.maxY)
    }
}

/// A window that keeps the constraint sets AppKit reports as unsatisfiable. AppKit hands each set to
/// `visualizeConstraints(_:)` when `NSConstraintBasedLayoutVisualizeMutuallyExclusiveConstraints` is on
/// (registered here, in memory only).
@MainActor final class ConflictRecordingWindow: NSWindow {
    private(set) var conflicts: [[NSLayoutConstraint]] = []

    override init(contentRect: NSRect, styleMask style: NSWindow.StyleMask, backing: NSWindow.BackingStoreType, defer flag: Bool) {
        UserDefaults.standard.register(defaults: ["NSConstraintBasedLayoutVisualizeMutuallyExclusiveConstraints": true])
        super.init(contentRect: contentRect, styleMask: style, backing: backing, defer: flag)
    }

    override func visualizeConstraints(_ constraints: [NSLayoutConstraint]?) {
        conflicts.append(constraints ?? [])
    }

    /// The reported sets with a vertical constraint in them (a 0-wide layout's horizontal ones are another matter).
    var verticalConflicts: [[NSLayoutConstraint]] {
        conflicts.filter { set in set.contains { $0.firstAttribute.isVertical || $0.secondAttribute.isVertical } }
    }
}

extension NSLayoutConstraint.Attribute {
    var isVertical: Bool { [.top, .bottom, .height, .centerY, .firstBaseline, .lastBaseline].contains(self) }
}
