import AppKit
@testable import CmuxNextBrowser
import CmuxNextDesign
import Testing

/// The omnibar's machine, profile and focus-mode badges and its bookmark star lay out by frames
/// (``ChipLayout``), not Auto Layout. Each holds no constraint of its own and reports its size
/// through its intrinsic size, which the omnibar's badge row reads.
@MainActor @Suite struct OmnibarBadgeFrameLayoutTests {
    static func usesFrames(_ view: NSView) -> Bool {
        view.constraints.allSatisfy { String(describing: type(of: $0)) != "NSLayoutConstraint" }
            && view.subviews.allSatisfy { $0.translatesAutoresizingMaskIntoConstraints }
    }

    static func label(in view: NSView) -> ChromeLabel? { view.subviews.compactMap { $0 as? ChromeLabel }.first }

    static func alignment(_ view: NSView) -> CGRect { view.alignmentRect(forFrame: view.frame) }

    static func close(_ a: CGFloat, _ b: CGFloat) -> Bool { abs(a - b) < 0.01 }

    @Test func theMachineChipIsEighteenTallAndAtMost160Wide() throws {
        _ = NSApplication.shared
        let badge = MachineBadgeView(frame: .zero)
        badge.show(text: "mac-mini", help: "mac-mini")
        #expect(Self.usesFrames(badge))
        let label = try #require(Self.label(in: badge))
        let size = badge.intrinsicContentSize
        #expect(size.height == 18)
        #expect(size.width == (label.intrinsicContentSize.width + 12).rounded(.up))

        badge.show(text: String(repeating: "a-very-long-machine-name-", count: 6), help: "long")
        #expect(badge.intrinsicContentSize.width == 160, "a long name truncates inside 160 pt")
        badge.frame = CGRect(origin: .zero, size: badge.intrinsicContentSize)
        badge.layoutSubtreeIfNeeded()
        #expect(Self.close(Self.alignment(label).minX, 6))
        #expect(Self.close(Self.alignment(label).width, 148))
    }

    @Test func theFocusChipPutsItsGlyphBeforeTheTextInReadingOrder() throws {
        _ = NSApplication.shared
        let badge = FocusModeBadgeView(frame: .zero)
        #expect(Self.usesFrames(badge))
        let label = try #require(Self.label(in: badge))
        let glyph = try #require(badge.subviews.compactMap { $0 as? NSImageView }.first)
        let size = badge.intrinsicContentSize
        #expect(size.height == 18)
        #expect(size.width == (6 + glyph.intrinsicContentSize.width + 4 + label.intrinsicContentSize.width + 6).rounded(.up))

        badge.frame = CGRect(origin: .zero, size: size)
        badge.layoutSubtreeIfNeeded()
        #expect(Self.close(Self.alignment(glyph).minX, 6))
        #expect(Self.alignment(label).minX > Self.alignment(glyph).maxX)

        badge.userInterfaceLayoutDirection = .rightToLeft
        badge.needsLayout = true
        badge.layoutSubtreeIfNeeded()
        #expect(Self.close(Self.alignment(glyph).maxX, size.width - 6), "right to left, the glyph leads at the right edge")
        #expect(Self.alignment(label).maxX < Self.alignment(glyph).minX)
    }

    @Test func armingTheExitAsksForTheNewTextsWidth() {
        _ = NSApplication.shared
        let badge = FocusModeBadgeView(frame: .zero)
        let before = badge.intrinsicContentSize
        badge.show(armed: true)
        #expect(badge.intrinsicContentSize.width != before.width)
    }

    @Test func theProfileBadgeCentersItsMonogramInSixteenPoints() throws {
        _ = NSApplication.shared
        let badge = ProfileBadgeView(frame: .zero)
        badge.show(BrowserProfileBadge(monogram: "W", color: .blue, name: "Work"))
        #expect(Self.usesFrames(badge))
        #expect(badge.intrinsicContentSize == CGSize(width: ProfileBadgeView.size, height: ProfileBadgeView.size))
        badge.frame = CGRect(origin: .zero, size: badge.intrinsicContentSize)
        badge.layoutSubtreeIfNeeded()
        let label = try #require(Self.label(in: badge))
        let rect = Self.alignment(label)
        #expect(abs(rect.midX - 8) <= 0.5)
        #expect(abs(rect.midY - 8) <= 0.5)
    }

    @Test func theBookmarkStarCentersItsGlyphInItsSquare() throws {
        _ = NSApplication.shared
        let star = BookmarkStarButton(frame: .zero)
        star.state = .off
        #expect(Self.usesFrames(star))
        let side = ProfileBadgeView.size + 4
        #expect(star.intrinsicContentSize == CGSize(width: side, height: side))
        #expect(star.fittingSize == star.intrinsicContentSize)
        star.frame = CGRect(origin: .zero, size: star.intrinsicContentSize)
        star.layoutSubtreeIfNeeded()
        let glyph = try #require(star.subviews.compactMap { $0 as? NSImageView }.first)
        let rect = Self.alignment(glyph)
        #expect(rect.size == glyph.intrinsicContentSize)
        #expect(abs(rect.midX - side / 2) <= 0.5)
        #expect(abs(rect.midY - side / 2) <= 0.5)

        star.state = .on
        star.frame = CGRect(origin: .zero, size: CGSize(width: side + 10, height: side))
        star.layoutSubtreeIfNeeded()
        #expect(abs(Self.alignment(glyph).midX - (side + 10) / 2) <= 0.5, "a wider frame centers the glyph again")
    }

    @Test func centeringIsOnWholePointsAndNeverNegative() {
        let bounds = CGRect(x: 0, y: 0, width: 16, height: 16)
        #expect(ProfileBadgeView.centered(CGSize(width: 7, height: 11), in: bounds) == CGRect(x: 5, y: 3, width: 7, height: 11))
        #expect(ProfileBadgeView.centered(CGSize(width: -1, height: -1), in: bounds) == CGRect(x: 8, y: 8, width: 0, height: 0))
    }
}
