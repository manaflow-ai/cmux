import AppKit
@testable import CmuxNextBrowser
import CmuxNextTestSupport
import Foundation
import Testing

/// #32909 (lead, 2026-11-03): Shift-Cmd-L's key turn still built parts of the omnibar its first frame
/// does not show: the four trailing badges (focus mode, profile, machine, bookmark star), the
/// suggestion card's top and the omnibar's own field editor. Each is made on first use, and works
/// as before then.
@MainActor @Suite(.serialized, .closesItsWindows) struct OmnibarFirstFrameTests {
    static func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }

    static func shown(_ bar: AddressBarView) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 80), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView?.addSubview(bar)
        if let content = window.contentView {
            NSLayoutConstraint.activate([
                bar.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 10),
                bar.widthAnchor.constraint(equalToConstant: 840),
                bar.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            ])
        }
        bar.update(url: URL(string: "https://example.com/"), security: .secure)
        window.contentView?.layoutSubtreeIfNeeded()
        return window
    }

    @Test func aNewOmnibarBuildsOnlyWhatItsFirstFrameShows() {
        let bar = AddressBarView()
        let window = Self.shown(bar)
        defer { window.closeAfterTest() }
        bar.setMachineBadge(nil, help: nil)
        bar.setProfileBadge(nil)
        bar.setBookmarkStar(.hidden)
        bar.setFocusModeBadge(armed: nil)
        let views = Self.descendants(of: bar)
        let unshown = views.filter {
            $0 is FocusModeBadgeView || $0 is ProfileBadgeView || $0 is MachineBadgeView || $0 is BookmarkStarButton || $0 is OmnibarCardTopView
        }.map { String(describing: type(of: $0)) }
        #expect(unshown.isEmpty, "the first frame shows none of these, yet they were built: \(unshown)")
        let cell = bar.field.cell as? NSTextFieldCell
        #expect(cell.map { Mirror(reflecting: $0).children.contains { $0.value is OmnibarFieldEditor } } != true,
                "the omnibar's field editor was built before the field edits")
    }

    @Test func theStarAndTheBadgesStillShowWhenAsked() {
        let bar = AddressBarView()
        let window = Self.shown(bar)
        defer { window.closeAfterTest() }
        var presses = 0
        bar.onBookmarkStar = { _ in presses += 1 }
        bar.setBookmarkStar(.off)
        bar.setProfileBadge(BrowserProfileBadge(monogram: "A", color: nil, name: "Austin"))
        window.contentView?.layoutSubtreeIfNeeded()
        #expect(bar.bookmarkStarState == .off)
        let star = Self.descendants(of: bar).compactMap { $0 as? BookmarkStarButton }.first
        #expect(star?.isHidden == false, "the star shows for a bookmarkable page")
        #expect(bar.profileBadgeName != nil, "the profile badge shows")
        star?.onPress?(star ?? bar)
        #expect(presses == 1, "the star's press handler set before the star existed reaches it")
        #expect(bar.textArea.maxX <= (star.map { $0.convert($0.bounds, to: bar).minX } ?? 0), "the text ends before the badges")
    }
}
