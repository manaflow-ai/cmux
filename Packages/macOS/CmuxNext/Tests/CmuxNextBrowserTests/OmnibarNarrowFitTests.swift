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
        return found
    }

    @Test(arguments: [70, 90, 110, 140, 180, 240, 320, 480, 840] as [CGFloat])
    func theURLTextEndsBeforeEveryTrailingIcon(width: CGFloat) {
        let (bar, window, _) = bar(width: width)
        defer { window.closeAfterTest() }
        #expect(problems(bar).isEmpty, "at \(width) pt: \(problems(bar))")
    }
}
