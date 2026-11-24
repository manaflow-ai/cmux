import AppKit
@testable import CmuxNextApp
import CmuxNextDesign
import Testing

/// `PaneContentRidesTests`, the app's internal pages. Home (the docked Home and the Home tab), Markdown, the file
/// viewer, Settings and each other internal page have one view class. A pane that shows one rides its move, and its
/// host holds the page while the pane gets smaller, as it holds a browser page: an act on a pane that shows Home
/// moves each pane of the act, and does not show in one frame.
extension PaneContentRidesTests {
    /// Pages of that one class: the two Homes, the file viewer, Markdown and Settings.
    nonisolated static let internalPages = ["the docked Home", "the Home tab", "the file viewer", "Markdown", "Settings"]

    static func internalPage(_ name: String) -> InternalPageID {
        switch name {
        case "the docked Home": .homeDock
        case "the Home tab": .homeTab
        case "the file viewer": .editor
        case "Markdown": .markdown
        default: .settings
        }
    }

    /// The app's own content area with the app's own internal page view as the top view that fills it: the pane's
    /// content rides, and the page is the view that keeps its own picture in a move.
    @Test(arguments: internalPages)
    func aPaneThatShowsAnInternalPageRidesAndThePageKeepsItsOwnPicture(_ name: String) {
        _ = NSApplication.shared
        #expect(Self.isOfThePagesKind(InternalPageView.self), "the internal page view is not of the pages' kind: an act on its pane shows in one frame")
        let content = NSView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        let area = PaneContentAreaView(frame: content.bounds)
        content.addSubview(area)
        #expect(!content.paneRidesCommitMotion, "SETUP: a pane content whose area shows no view rides")
        let page = InternalPageView(key: "pane-rides-\(name)", page: Self.internalPage(name), content: NSView())
        page.frame = area.bounds
        area.addSubview(page)
        #expect(content.paneRidesCommitMotion, "a pane that shows \(name) does not ride: an act that changes its pane shows in one frame, for each pane of the act")
        #expect(content.paneCommitMotionHolder === page, "\(name) is not the view that keeps its pane's old picture in a move")
        #expect(page.paneCommitMotionHoldKind == .ownPicture, "\(name) does not keep its own picture: its host does not hold it while its pane gets smaller")
        // A page that does not show (a parked tab) stops no ride and gives none.
        page.isHidden = true
        #expect(!content.paneRidesCommitMotion && content.paneCommitMotionHolder == nil, "a hidden \(name) rides or holds")
    }
}

/// A page that draws in a window of its own over its pane, as a cmux page on the Chromium engine does.
@MainActor private final class OwnWindowPage: NSView, PaneContentOwnWindow {
    var drawsInOwnWindow = true
}

extension PaneContentRidesTests {
    /// The Markdown zoom of Lawrence's 2026-11-23 film: an internal page on the Chromium engine draws in Chromium's
    /// child window, which the pane's moving clip does not cut. A pane that shows it does not ride: a zoom or an
    /// unzoom of it shows in one frame, so the covered panes never show through the page and the page wraps its text
    /// once. The same page on WebKit (no window of its own) rides.
    @Test(arguments: internalPages)
    func aPaneWhoseInternalPageDrawsInItsOwnWindowDoesNotRide(_ name: String) {
        _ = NSApplication.shared
        let content = NSView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        let area = PaneContentAreaView(frame: content.bounds)
        content.addSubview(area)
        let page = OwnWindowPage()
        let view = InternalPageView(key: "pane-own-window-\(name)", page: Self.internalPage(name), content: page)
        view.frame = area.bounds
        area.addSubview(view)
        view.layoutSubtreeIfNeeded()
        #expect(!content.paneRidesCommitMotion,
                "a pane that shows \(name) in a window of its own rides: the move's clip does not cut that window, and the panes under it show through")
        page.drawsInOwnWindow = false
        #expect(content.paneRidesCommitMotion, "a pane that shows \(name) in its own layer does not ride")
    }
}
