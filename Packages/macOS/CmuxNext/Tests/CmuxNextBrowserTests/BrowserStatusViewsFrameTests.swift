import AppKit
@testable import CmuxNextBrowser
import CmuxNextDesign
import CmuxNextWakeups
import Testing

/// The browser's status views and bars lay out by frame: each places its
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

    /// A narrow pane: the three answers do not fit side by side, so they stack inside the bar,
    /// each as wide as it less its padding, in reading order from the top, in either direction.
    @Test(arguments: [false, true]) func aNarrowBarStacksItsAnswersInsideIt(rightToLeft: Bool) {
        let bar = PromptBarView(frame: .zero)
        if rightToLeft { bar.userInterfaceLayoutDirection = .rightToLeft }
        bar.show(Self.permission())
        let size = bar.size(fittingWidth: 220)
        bar.setFrameSize(size)
        bar.layout()
        let padding = BrowserMetrics.overlayPadding
        let inner = bar.bounds.insetBy(dx: padding, dy: padding)
        let answers = Self.buttons(in: bar).map(Self.alignmentRect)
        #expect(answers.count == 3)
        #expect(answers.allSatisfy { Self.contains(inner, $0) }, "inside \(inner): \(answers)")
        #expect(answers.allSatisfy { abs($0.width - inner.width) < 0.01 }, "each as wide as the bar: \(answers)")
        #expect(zip(answers, answers.dropFirst()).allSatisfy { $0.minY >= $1.maxY }, "top to bottom, no overlap: \(answers)")
    }

    /// The "Page unresponsive" card's Exit page / Wait row stacks the same way in a narrow page.
    @Test(arguments: [false, true]) func aNarrowUnresponsiveCardStacksItsAnswersInsideIt(rightToLeft: Bool) {
        let card = PageUnresponsiveView(frame: .zero)
        if rightToLeft { card.userInterfaceLayoutDirection = .rightToLeft }
        card.setFrameSize(card.size(fittingWidth: 120))
        card.layout()
        let padding = BrowserMetrics.overlayPadding
        let inner = card.bounds.insetBy(dx: padding, dy: padding)
        let answers = Self.leaves(of: card).filter { $0 is ChromeTextButton }.map(Self.alignmentRect)
        #expect(answers.count == 2)
        #expect(answers.allSatisfy { Self.contains(inner, $0) }, "inside \(inner): \(answers)")
        #expect(!answers[0].intersects(answers[1]), "\(answers)")
    }

    /// The pane narrows, then widens again: the bar is measured in each new room, never left at
    /// the narrow size with its message wrapped tall.
    @Test func thePromptBarFollowsItsPaneWhenItWidens() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let page = WebKitEngine(fileInput: NoFileInput(), stores: .inMemory()).makeWebKitTab()
        let chrome = BrowserChromeView(tab: page, mainWork: MainWorkScheduler(budget: MainFrameBudget()), node: nil)
        chrome.frame = window.contentLayoutRect
        window.contentView = chrome
        window.orderFrontRegardless()
        defer {
            chrome.addressBar.dismissRows()
            window.orderOut(nil)
            window.close()
            page.close()
        }
        page.enqueuePrompt(.permission(.camera), origin: "https://example.com") { _ in }
        chrome.renderPrompt()
        let bar = chrome.promptBar
        let inset = BrowserMetrics.overlayInset
        chrome.layoutSubtreeIfNeeded()
        #expect(!bar.isHidden)

        window.setContentSize(NSSize(width: 360, height: 600))
        chrome.layoutSubtreeIfNeeded()
        #expect(chrome.bounds.width == 360)
        let narrow = bar.frame.size
        #expect(Self.near(narrow, bar.size(fittingWidth: 360 - inset * 2)), "the narrow room: \(narrow)")

        window.setContentSize(NSSize(width: 900, height: 600))
        chrome.layoutSubtreeIfNeeded()
        let wide = bar.size(fittingWidth: 900 - inset * 2)
        #expect(wide.width > narrow.width + 1 && wide.height < narrow.height - 1, "precondition: the room changes the bar")
        #expect(Self.near(bar.frame.size, wide), "widened again: \(bar.frame.size), measured \(wide)")
    }

    /// Auto Layout puts frames on the backing pixel grid.
    private static func near(_ size: CGSize, _ other: CGSize) -> Bool {
        abs(size.width - other.width) <= 1 && abs(size.height - other.height) <= 1
    }

    /// Frame-laid buttons hold no required size constraints: a hidden one (the notice's absent
    /// action, the error page's certificate buttons) keeps the zero frame its parent leaves it,
    /// which a required height of `controlHeight` could not satisfy.
    @Test func frameLaidButtonsBreakNoConstraint() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 500), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer {
            window.orderOut(nil)
            window.close()
        }
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 500))
        window.contentView = root
        let notice = BrowserNoticeView(frame: NSRect(x: 0, y: 0, width: 300, height: BrowserMetrics.findBarHeight))
        notice.text = "Chromium could not start"
        let error = LoadErrorView(frame: NSRect(x: 0, y: 40, width: 600, height: 460))
        error.show(BrowserLoadError(domain: NSURLErrorDomain, code: NSURLErrorCannotFindHost, message: "The server could not be found."))
        root.addSubview(notice)
        root.addSubview(error)
        root.layoutSubtreeIfNeeded()
        #expect(error.backButton.isHidden && error.proceedButton.isHidden, "precondition: hidden buttons")
        let broken = Self.brokenSizeConstraints(in: notice) + Self.brokenSizeConstraints(in: error)
        #expect(broken.isEmpty, "\(broken)")
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

    private static func contains(_ outer: CGRect, _ inner: CGRect) -> Bool {
        inner.minX >= outer.minX - 0.01 && inner.maxX <= outer.maxX + 0.01
            && inner.minY >= outer.minY - 0.01 && inner.maxY <= outer.maxY + 0.01
    }

    /// The required width and height constants that `root`'s frame-laid subviews hold (their
    /// autoresizing constraints are their superview's). Each fights the frame the parent sets
    /// (zero while hidden, cut when narrow): Auto Layout logs the conflict and drops one, and may
    /// move the frame to hide it, so the test reads the constraints, not the frames.
    private static func brokenSizeConstraints(in root: NSView) -> [String] {
        var broken: [String] = []
        func visit(_ view: NSView) {
            if view !== root, view.translatesAutoresizingMaskIntoConstraints {
                for constraint in view.constraints where constraint.isActive && constraint.priority == .required
                    && constraint.firstItem === view && constraint.secondItem == nil
                    && [.width, .height].contains(constraint.firstAttribute) {
                    broken.append("\(type(of: view))\(view.isHidden ? " hidden" : "") \(view.frame) \(constraint)")
                }
            }
            view.subviews.forEach(visit)
        }
        visit(root)
        return broken
    }

    private static func leaves(of view: NSView) -> [NSView] {
        view.subviews.flatMap { $0.subviews.isEmpty || $0 is NSButton ? [$0] : leaves(of: $0) }
    }
}
