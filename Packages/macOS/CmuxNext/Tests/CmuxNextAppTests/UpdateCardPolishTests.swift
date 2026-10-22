import AppKit
@testable import CmuxNextApp
import CmuxNextDesign
@testable import CmuxNextSidebar
@testable import CmuxNextUpdater
import Foundation
import Testing

/// The update cards' polish (Lawrence 2026-10-21): the download's byte counts and percent do not
/// jitter as they tick (tabular digits), the Update Ready card has no Automatic Updates row (the
/// same setting is Settings' Download Updates Automatically, on by default), and Restart to Update
/// is the app's bordered button again, as before the primary fill.
@MainActor @Suite(.serialized) struct UpdateCardPolishTests {
    static let mb: UInt64 = 1_000_000

    /// True when every digit of `font` is as wide as every other (tabular figures).
    static func hasTabularDigits(_ font: NSFont) -> Bool {
        let widths = Set((0...9).map { digit in
            ("\(digit)\(digit)\(digit)" as NSString).size(withAttributes: [.font: font]).width
        })
        return widths.count == 1
    }

    /// The label of `view` (or one of its descendants) drawing `text`.
    static func label(in view: NSView, showing text: String) -> NSTextField? {
        if let field = view as? NSTextField, field.stringValue == text { return field }
        for child in view.subviews {
            if let found = label(in: child, showing: text) { return found }
        }
        return nil
    }

    @Test func theDownloadsByteCountsAndPercentUseTabularDigits() throws {
        let presentation = UpdateCard.downloading(.downloading(received: 189 * Self.mb, expected: 226 * Self.mb))
            .presentation(version: "1.0.0", build: "100")
        let notice = SidebarCardFeed.notice(presentation, asked: true)
        let detail = try #require(notice.detail)
        let card = SidebarNoticeCardView(frame: NSRect(x: 0, y: 0, width: 240, height: SidebarNoticeCardView.height(for: notice)))
        card.configure(notice)
        card.layoutSubtreeIfNeeded()
        let label = try #require(Self.label(in: card, showing: detail), "no label shows \(detail)")
        let font = try #require(label.font)
        #expect(Self.hasTabularDigits(font), "the download's \(detail) is drawn in proportional digits: it jitters as it ticks")
    }

    @Test func theUpdateReadyCardHasNoAutomaticUpdatesRow() {
        let card = SidebarUpdateCardView(frame: NSRect(x: 0, y: 0, width: 216, height: 120))
        let model = SidebarUpdateCard(title: "Update Ready", detail: "nightly 3969569 · Oct 21", buttonTitle: "Restart to Update",
                                      notes: .init(headline: "Update Ready", keepsRunning: ""))
        card.configure(model)
        card.frame.size.height = SidebarUpdateCardView.height(for: model)
        card.layoutSubtreeIfNeeded()
        let automatic = card.subviews.filter { !$0.isHidden && $0.accessibilityIdentifier() == "cmux.sidebar.update.automatic" }
        #expect(automatic.isEmpty, "the card repeats Settings' Download Updates Automatically as its own row")
        #expect(Self.label(in: card, showing: "Automatic Updates") == nil)
        // Title, detail and the button: nothing between the detail and Restart to Update but the gap.
        let detail = Self.label(in: card, showing: "nightly 3969569 · Oct 21")
        let button = card.subviews.first { $0.accessibilityIdentifier() == "cmux.sidebar.update.install" }
        if let detail, let button {
            #expect(button.frame.minY - detail.frame.maxY <= Metrics.space2 + 0.5, "a row still sits between the detail and the button")
        } else {
            Issue.record("the card lost its detail or its button")
        }
    }

    @Test func restartToUpdateIsTheBorderedAppButtonAgain() {
        #expect(SidebarTunables.updateCardButton.defaultValue == .bordered)
        let button = SidebarUpdateButton(frame: NSRect(x: 0, y: 0, width: 180, height: SidebarUpdateButton.height))
        button.configure(title: "Restart to Update", enabled: true, help: nil)
        button.updateLayer()
        #expect(button.layer?.backgroundColor == button.performWithTheme { Palette.hoverFill.cgColor })
        #expect((button.layer?.borderWidth ?? 0) > 0, "the bordered button lost its hairline")
    }
}
