import AppKit
@testable import CmuxNextBrowser
import CmuxNextDesign
import CmuxNextTestSupport
import Foundation
import Testing

/// A browser pane's chrome first lays out in a content area of zero size (`PaneContentAreaView()` starts at
/// `.zero`; its pane gives it a frame later). When the toolbar row's links were all required, the row could not fit
/// there and AppKit broke links of its own choosing inside the omnibar (the chip-to-address gap, the badges' edge,
/// the star's and the profile badge's widths: the user's nightly log, 2026-11-11 19:56). A broken link stays broken,
/// so once the pane was wide the address took its whole text's width and ran past the star and under the extension
/// buttons (user, 2026-11-11 20:05: "omnibar overflow text has issue"). Every required link of the chrome must hold
/// at zero size and after it.
@MainActor @Suite(.serialized, .closesItsWindows) struct BrowserToolbarZeroSizeTests {
    static let longURL = URL(string: "https://tandemspace.com/office/9428bd16-cf52-4f24-99e8-dfd2abca5f9e"
        + "?from=admin_matchmaking&utm_source=a-long-query-string-that-overflows-the-omnibar&utm_campaign=more")!

    @Test func everyRequiredLinkHoldsAtZeroSizeAndAfter() throws {
        let tab = MockBrowserEngine(kind: .cef).makeMockTab(BrowserTabConfiguration(initialURL: Self.longURL))
        tab.load(Self.longURL)
        let pane = BrowserPaneChrome()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 700), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer {
            window.close()
            pane.drop()
            tab.close()
        }
        let root = try #require(window.contentView)
        let area = PaneContentAreaView()
        root.addSubview(area)
        let chrome = pane.bind(tab, state: BrowserChromeTabState())
        chrome.frame = area.bounds
        chrome.autoresizingMask = [.width, .height]
        area.addSubview(chrome)
        root.layoutSubtreeIfNeeded()
        let atZero = Self.brokenRequiredLinks(under: area, in: root)
        #expect(atZero.isEmpty, "required links broken at zero size:\n\(atZero.joined(separator: "\n"))")

        area.frame = NSRect(x: 0, y: 0, width: 1100, height: 600)
        root.layoutSubtreeIfNeeded()
        let after = Self.brokenRequiredLinks(under: area, in: root)
        #expect(after.isEmpty, "required links broken once the pane has its size:\n\(after.joined(separator: "\n"))")

        let bar = chrome.addressBar
        let field = bar.field
        let text = field.alignmentRect(forFrame: field.frame)
        #expect(chrome.frame == area.bounds, "the chrome fills its content area: \(chrome.frame) in \(area.bounds)")
        #expect(text.width < 1000, "the address is as wide as the omnibar lets it be, not as its text: \(text)")
        #expect(text.minX >= bar.chip.frame.maxX, "the address starts after the page-info chip: \(text), chip \(bar.chip.frame)")
        #expect(text.maxX <= bar.bounds.maxX - OmnibarStyle.trailingPadding + 0.5, "the address ends inside the omnibar: \(text), bar \(bar.bounds)")
        if !bar.starButton.isHidden {
            let star = bar.starButton.convert(bar.starButton.bounds, to: bar)
            #expect(text.maxX <= star.minX, "the address ends before the star: \(text), star \(star)")
        }
    }

    /// The required constraints held by `top` and the views under it that the laid-out frames do not meet, as text.
    static func brokenRequiredLinks(under top: NSView, in space: NSView) -> [String] {
        var pending = [top], views: [NSView] = []
        while let view = pending.popLast() {
            views.append(view)
            pending += view.subviews
        }
        var broken: [String] = []
        for view in views {
            // A content-size link (intrinsic size) reports required but gives at its hugging and resistance priorities.
            for link in view.constraints where link.isActive && link.priority == .required && !String(describing: type(of: link)).contains("ContentSize") {
                guard let first = value(link.firstItem, link.firstAttribute, in: space) else { continue }
                let second: CGFloat
                if link.secondAttribute == .notAnAttribute {
                    second = link.constant
                } else {
                    guard let other = value(link.secondItem, link.secondAttribute, in: space) else { continue }
                    second = other * link.multiplier + link.constant
                }
                let holds = switch link.relation {
                case .equal: abs(first - second) <= 0.5
                case .lessThanOrEqual: first <= second + 0.5
                case .greaterThanOrEqual: first >= second - 0.5
                @unknown default: true
                }
                if !holds { broken.append("\(link): \(first) vs \(second)") }
            }
        }
        return broken
    }

    /// The value of `attribute` of a view's alignment rect or a guide's frame, in `space`, with y down (as
    /// constraints read top and bottom). Nil for baselines and items outside the window.
    private static func value(_ item: AnyObject?, _ attribute: NSLayoutConstraint.Attribute, in space: NSView) -> CGFloat? {
        let rect: NSRect
        if let view = item as? NSView, let superview = view.superview {
            rect = space.convert(view.alignmentRect(forFrame: view.frame), from: superview)
        } else if let guide = item as? NSLayoutGuide, let owner = guide.owningView {
            rect = space.convert(guide.frame, from: owner)
        } else {
            return nil
        }
        let top = space.isFlipped ? rect.minY : space.bounds.height - rect.maxY
        switch attribute {
        case .left, .leading: return rect.minX
        case .right, .trailing: return rect.maxX
        case .centerX: return rect.midX
        case .width: return rect.width
        case .height: return rect.height
        case .top: return top
        case .bottom: return top + rect.height
        case .centerY: return top + rect.height / 2
        default: return nil
        }
    }
}
