import AppKit
@testable import CmuxNextBrowser
import Testing

/// The browser's status views and bars lay out by frame (p03-rendering-072): each places its
/// subviews in `layout()` from its bounds, with no Auto Layout, in narrow, normal and wide
/// rooms, right to left, and with their accessories (fields, an action button).
@MainActor @Suite(.serialized) struct BrowserStatusViewsFrameTests {
    private static func permission() -> BrowserPrompt {
        BrowserPrompt(kind: .permission(.camera), origin: "https://example.com") { _ in }
    }

    private static func credentials() -> BrowserPrompt {
        BrowserPrompt(kind: .credentials(host: "example.com", realm: "Staff"), origin: "https://example.com") { _ in }
    }

    private static func buttons(in bar: PromptBarView) -> [PromptResponseButton] {
        PasswordPromptBarTests.responseButtons(in: bar)
    }

    // MARK: Prompt bar

    @Test func thePromptBarTakesItsWidthFromTheRoom() {
        let bar = PromptBarView(frame: .zero)
        bar.show(Self.permission())
        let wide = bar.size(fittingWidth: 2000)
        #expect(wide.width <= BrowserMetrics.promptMaxWidth && wide.width >= BrowserMetrics.promptMinWidth)
        let narrow = bar.size(fittingWidth: 200)
        #expect(narrow.width == 200, "a narrow pane narrows the bar")
        #expect(narrow.height >= wide.height, "the message wraps at the narrower width")
    }

    @Test func thePromptBarsAnswersRunInReadingOrderAndMirror() {
        let bar = PromptBarView(frame: .zero)
        bar.show(Self.permission())
        bar.setFrameSize(bar.size(fittingWidth: 600))
        bar.layout()
        let ltr = Self.buttons(in: bar).map(Self.alignmentRect)
        #expect(ltr.count == 3)
        #expect(zip(ltr, ltr.dropFirst()).allSatisfy { $0.maxX <= $1.minX }, "left to right, no overlap: \(ltr)")
        #expect(ltr.allSatisfy { $0.minX >= 0 && $0.maxX <= bar.bounds.width })

        bar.userInterfaceLayoutDirection = .rightToLeft
        bar.layout()
        let rtl = Self.buttons(in: bar).map(Self.alignmentRect)
        #expect(zip(rtl, rtl.dropFirst()).allSatisfy { $0.minX >= $1.maxX }, "right to left: \(rtl)")
        let trailing = bar.bounds.width - BrowserMetrics.overlayPadding
        #expect(abs((rtl.first?.maxX ?? 0) - trailing) < 0.01, "the first answer at the leading (right) edge")
    }

    /// The sign-in prompt's fields fill the bar less its padding, under the message.
    @Test func theSignInFieldsFillTheBar() {
        let bar = PromptBarView(frame: .zero)
        bar.show(Self.credentials())
        let permissionBar = PromptBarView(frame: .zero)
        permissionBar.show(Self.permission())
        let size = bar.size(fittingWidth: 600)
        #expect(size.height > permissionBar.size(fittingWidth: 600).height, "two fields make the bar taller")
        bar.setFrameSize(size)
        bar.layout()
        let padding = BrowserMetrics.overlayPadding
        for field in [bar.userField, bar.passwordField] as [NSView] {
            #expect(Self.alignmentRect(field).width == size.width - padding * 2)
            #expect(Self.alignmentRect(field).height == BrowserMetrics.controlHeight)
        }
        #expect(bar.userField.frame.minY > bar.passwordField.frame.maxY, "user name above password")
    }

    // MARK: Notice pill

    @Test func theNoticeFitsItsTextUpToThePromptWidth() {
        let notice = BrowserNoticeView(frame: .zero)
        notice.text = "Short"
        let short = notice.cardSize(maxWidth: 2000)
        #expect(short.width < BrowserMetrics.promptMaxWidth)
        #expect(short.height == BrowserMetrics.findBarHeight)
        notice.text = String(repeating: "A long notice that runs past the prompt width. ", count: 6)
        #expect(notice.cardSize(maxWidth: 2000).width == BrowserMetrics.promptMaxWidth)
        #expect(notice.cardSize(maxWidth: 150).width == 150)
    }

    /// The accessory: an action button widens the pill and sits between the text and close.
    @Test func theNoticeActionSitsBeforeClose() {
        let notice = BrowserNoticeView(frame: .zero)
        notice.text = "Chromium could not start"
        let plain = notice.cardSize(maxWidth: 2000).width
        notice.action = ("Retry", {})
        let withAction = notice.cardSize(maxWidth: 2000)
        #expect(withAction.width > plain)

        // Narrow: the text truncates, the buttons keep their widths inside the pill.
        notice.setFrameSize(CGSize(width: 160, height: withAction.height))
        notice.layout()
        let report = notice.layoutReport.joined(separator: "\n")
        let shown = Self.leaves(of: notice).filter { !$0.isHidden && ($0 is NSButton || $0 is any ShownText) }
        #expect(shown.count == 3, "\(report)")
        #expect(shown.allSatisfy { $0.frame.minX >= 0 && $0.frame.maxX <= 160 }, "\(report)")
    }

    // MARK: Status views

    @Test func theStatusViewsCoverThePageAndCenterTheCard() {
        let parent = NSView(frame: NSRect(x: 0, y: 0, width: 700, height: 500))
        let status = PageStatusViews()
        status.install(in: parent) { nil }
        let page = CGRect(x: 0, y: 0, width: 700, height: 440)
        status.layout(over: page)
        #expect(status.errorView.frame == page && status.goneView.frame == page)

        status.unresponsiveView.isHidden = false
        status.layout(over: page)
        let card = status.unresponsiveView.frame
        #expect(card.width >= BrowserMetrics.promptMinWidth && card.width <= BrowserMetrics.promptMaxWidth)
        #expect(abs(card.midX - page.midX) <= 1 && abs(card.midY - page.midY) <= 1)

        // A narrow page: the card keeps its margin from the sides.
        let narrow = CGRect(x: 0, y: 0, width: 200, height: 440)
        status.layout(over: narrow)
        #expect(status.unresponsiveView.frame.minX >= PageStatusViews.cardMargin)
        #expect(status.unresponsiveView.frame.maxX <= narrow.maxX - PageStatusViews.cardMargin)
    }

    @Test func theErrorPageColumnStaysInsideANarrowPage() {
        let view = LoadErrorView(frame: NSRect(x: 0, y: 0, width: 220, height: 500))
        view.show(BrowserLoadError(domain: NSURLErrorDomain, code: NSURLErrorCannotFindHost,
                                   message: String(repeating: "The server could not be found. ", count: 8)))
        view.layout()
        let margin = PageMessageLayout.statusPageMargin
        let shown = view.subviews.filter { !$0.isHidden }
        #expect(!shown.isEmpty)
        for subview in shown {
            let rect = Self.alignmentRect(subview)
            #expect(rect.minX >= margin && rect.maxX <= 220 - margin, "\(type(of: subview)) \(rect)")
        }
        // The column fits: its middle is the page's, raised by the toolbar's height.
        let column = shown.map(Self.alignmentRect).reduce(CGRect.null) { $0.union($1) }
        #expect(abs(column.midY - (view.bounds.midY + BrowserMetrics.toolbarHeight)) <= 1, "\(column)")
    }

    private static func alignmentRect(_ view: NSView) -> CGRect {
        view.alignmentRect(forFrame: view.frame)
    }

    private static func leaves(of view: NSView) -> [NSView] {
        view.subviews.flatMap { $0.subviews.isEmpty || $0 is NSButton ? [$0] : leaves(of: $0) }
    }
}
