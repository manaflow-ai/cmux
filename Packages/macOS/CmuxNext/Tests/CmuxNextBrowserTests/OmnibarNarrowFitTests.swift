import AppKit
@testable import CmuxNextBrowser
import CmuxNextTestSupport
import Foundation
import Testing

/// In a narrow pane the omnibar's URL text ends before its trailing icons at every width (QA sweep-06675353 D7: at a
/// 203 pt pane the field showed the warning icon, a sliver of "N", "h." and the star, the URL running under the star).
/// As in Chrome, the "Not secure" label folds into its icon first, then the trailing badges give way, so the text keeps
/// room; the field never reaches under a shown badge nor starts under the chip.
@MainActor
@Suite(.closesItsWindows)
struct OmnibarNarrowFitTests {
    private func bar(width: CGFloat) -> (AddressBarView, NSWindow, NSLayoutConstraint) {
        let bar = AddressBarView()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 80), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView!.addSubview(bar)
        let widthConstraint = bar.widthAnchor.constraint(equalToConstant: width)
        NSLayoutConstraint.activate([
            bar.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 10),
            widthConstraint,
            bar.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 20),
        ])
        bar.update(url: URL(string: "http://127.0.0.1:8123/viewport.html?" + String(repeating: "long-url-segment-", count: 12)),
                   security: .insecure)
        bar.setBookmarkStar(.off)
        window.contentView!.layoutSubtreeIfNeeded()
        return (bar, window, widthConstraint)
    }

    /// The problems of `bar`'s layout: the field (the URL text) under a shown trailing badge, or starting under the chip,
    /// or with no room at all.
    private func problems(_ bar: AddressBarView) -> [String] {
        var found: [String] = []
        let field = bar.field.frame
        let chip = bar.pageInfoAnchor.frame
        if field.width < 1 { found.append("field has no width (\(field.width))") }
        if !bar.pageInfoAnchor.isHiddenOrHasHiddenAncestor, field.minX < chip.maxX - 0.5 {
            found.append("field starts at \(field.minX), under the chip ending at \(chip.maxX)")
        }
        for badge in [bar.starButton, bar.focusModeBadgeView] where !badge.isHiddenOrHasHiddenAncestor {
            let frame = badge.convert(badge.bounds, to: bar)
            if field.maxX > frame.minX + 0.5 { found.append("field ends at \(field.maxX), under \(type(of: badge)) at \(frame.minX)") }
        }
        if field.maxX > bar.bounds.maxX + 0.5 { found.append("field ends past the bar") }
        // The chip is never squeezed under its own content: a squeezed chip still draws its label at full width, over
        // the field (the sweep's "N" sliver before "h.").
        let content = bar.chip.intrinsicContentSize.width
        if chip.width + 0.5 < content { found.append("chip squeezed to \(chip.width) under its content \(content)") }
        // The text keeps a readable width whenever the bar has room for it beside the icon alone.
        let room = bar.bounds.width - OmnibarStyle.chipLeading - OmnibarStyle.chipSize - OmnibarStyle.textLeading - OmnibarStyle.trailingPadding
        let wanted = min(OmnibarNarrowFitTests.readableText, room)
        if field.width + 0.5 < wanted { found.append("field \(field.width) pt wide, under \(wanted)") }
        return found
    }

    /// About five characters of the omnibar's font (``OmnibarNarrowFit``'s minimum, spelled out so the test needs no
    /// type the fix adds).
    static let readableText: CGFloat = 40

    @Test(arguments: [70, 90, 110, 140, 180, 240, 320, 480, 840] as [CGFloat])
    func theURLTextEndsBeforeEveryTrailingIcon(width: CGFloat) {
        let (bar, window, _) = bar(width: width)
        defer { window.closeAfterTest() }
        #expect(abs(bar.frame.width - width) <= 0.5, "the bar is the width asked for, not one Auto Layout chose")
        #expect(problems(bar).isEmpty, "at \(width) pt: \(problems(bar))")
    }

    @Test func aWideBarKeepsTheNotSecureLabelAndTheStar() {
        let (bar, window, _) = bar(width: 840)
        defer { window.closeAfterTest() }
        #expect(!bar.chip.collapsesLabel)
        #expect(!bar.starButton.isHiddenOrHasHiddenAncestor)
    }

    @Test func aNarrowBarFoldsTheLabelFirstThenTheStar() {
        let (bar, window, width) = bar(width: 840)
        defer { window.closeAfterTest() }
        let labeled = bar.chip.labeledWidth
        // Room for the icon chip, the star and a short text, not for the label too: the label folds, the star stays.
        width.constant = OmnibarStyle.chipLeading + OmnibarStyle.chipSize + OmnibarStyle.textLeading + OmnibarNarrowFit.minimumTextWidth
            + OmnibarStyle.fieldTrailingGap + bar.starButton.fittingSize.width + OmnibarStyle.badgesTrailingInset + 4
        window.contentView!.layoutSubtreeIfNeeded()
        #expect(labeled > OmnibarStyle.chipSize + 20, "the insecure page has a label to fold")
        #expect(bar.chip.collapsesLabel)
        #expect(!bar.starButton.isHiddenOrHasHiddenAncestor)
        // Narrower still: the star gives way too.
        width.constant = 70
        window.contentView!.layoutSubtreeIfNeeded()
        #expect(bar.chip.collapsesLabel)
        #expect(bar.starButton.isHiddenOrHasHiddenAncestor)
        #expect(bar.bookmarkStarAnchor == nil)
        // Wide again: both come back.
        width.constant = 840
        window.contentView!.layoutSubtreeIfNeeded()
        #expect(!bar.chip.collapsesLabel)
        #expect(!bar.starButton.isHiddenOrHasHiddenAncestor)
        #expect(problems(bar).isEmpty)
    }

    @Test func theFitRuleFoldsTheLabelBeforeTheBadges() {
        func fit(_ width: CGFloat) -> OmnibarNarrowFit {
            OmnibarNarrowFit.resolve(barWidth: width, chipLeading: 2, chipIcon: 24, chipLabeled: 90, textLeading: 5,
                                     badges: 24, badgesInset: 2, fieldTrailingGap: 5, trailingPadding: 8, minimumText: 40)
        }
        // label 2+90+5, badges 5+24+2: text = width - 128.
        #expect(fit(400) == OmnibarNarrowFit(showsChipLabel: true, showsBadges: true))
        #expect(fit(168) == OmnibarNarrowFit(showsChipLabel: true, showsBadges: true))
        #expect(fit(167) == OmnibarNarrowFit(showsChipLabel: false, showsBadges: true))
        // icon 2+24+5, badges 31: text = width - 62.
        #expect(fit(102) == OmnibarNarrowFit(showsChipLabel: false, showsBadges: true))
        #expect(fit(101) == OmnibarNarrowFit(showsChipLabel: false, showsBadges: false))
        #expect(fit(20) == OmnibarNarrowFit(showsChipLabel: false, showsBadges: false))
        // No label, no badges: nothing to give way.
        #expect(OmnibarNarrowFit.resolve(barWidth: 50, chipLeading: 2, chipIcon: 24, chipLabeled: 24, textLeading: 5, badges: 0,
                                         badgesInset: 2, fieldTrailingGap: 5, trailingPadding: 8, minimumText: 40)
                == OmnibarNarrowFit(showsChipLabel: true, showsBadges: true))
    }
}
