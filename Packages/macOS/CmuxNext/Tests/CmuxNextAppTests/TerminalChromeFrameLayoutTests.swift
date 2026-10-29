import AppKit
import CmuxNextDesign
@testable import CmuxNextTerminal
import CmuxNextTerminalFind
import CmuxNextWakeups
import Testing

/// The terminal's status banner, "Sized for" chip, copy-mode badge and find bar
/// lay out by frames (``ChipLayout``), not Auto Layout: a pane resized every frame of a drag frames
/// them in `layout()` and solves no constraints. Each holds no constraint of its own, reports the
/// size the host frames it at, and lays its content out for narrow, normal, wide and right-to-left
/// frames.
@MainActor @Suite struct TerminalChromeFrameLayoutTests {
    /// The view holds no constraint written for it (system ones, such as an intrinsic size, aside)
    /// and every subview is framed.
    static func usesFrames(_ view: NSView) -> Bool {
        view.constraints.allSatisfy { String(describing: type(of: $0)) != "NSLayoutConstraint" }
            && view.subviews.allSatisfy { $0.translatesAutoresizingMaskIntoConstraints }
    }

    static func label(in view: NSView) -> ChromeLabel? { view.subviews.compactMap { $0 as? ChromeLabel }.first }

    static func alignment(_ view: NSView) -> CGRect { view.alignmentRect(forFrame: view.frame) }

    static func close(_ a: CGFloat, _ b: CGFloat) -> Bool { abs(a - b) < 0.01 }

    @Test func theBannerFramesItsLabelInItsInsets() throws {
        _ = NSApplication.shared
        let banner = TerminalStatusBanner()
        banner.show(.disconnected(.connectionLost, reconnecting: false))
        #expect(Self.usesFrames(banner))
        let label = try #require(Self.label(in: banner))
        let text = label.intrinsicContentSize
        let size = banner.fittingSize
        #expect(size == CGSize(width: (text.width + 24).rounded(.up), height: (text.height + 12).rounded(.up)))

        banner.frame = CGRect(origin: .zero, size: size)
        banner.layoutSubtreeIfNeeded()
        #expect(Self.close(Self.alignment(label).minX, 12))
        #expect(Self.close(Self.alignment(label).maxX, size.width - 12))

        // Narrow: the host gives it less than it asks for, and the label truncates.
        banner.frame.size.width = 120
        banner.layoutSubtreeIfNeeded()
        #expect(Self.close(Self.alignment(label).width, 96))
        banner.frame.size.width = 10
        banner.layoutSubtreeIfNeeded()
        #expect(Self.alignment(label).width == 0, "never a negative width")
    }

    @Test func aNewStatusTextAsksForANewSize() {
        _ = NSApplication.shared
        let banner = TerminalStatusBanner()
        banner.show(.restoring)
        let short = banner.fittingSize
        banner.show(.disconnected(.attachFailed, reconnecting: false))
        #expect(banner.fittingSize.width > short.width)
    }

    @Test func theSizedForChipTruncatesItsLabelNeverTakeOver() throws {
        _ = NSApplication.shared
        let chip = TerminalSizedForChip()
        chip.show(TerminalSizedFor(deviceName: "Maya's iPhone", deviceKind: "iphone", sameDevice: false,
                                   grid: TerminalGridSize(columns: 54, rows: 44)))
        #expect(Self.usesFrames(chip))
        let button = try #require(chip.subviews.compactMap { $0 as? NSButton }.first)
        let size = chip.fittingSize
        #expect(size.height >= 24)
        #expect(size == chip.chipLayout.preferredSize)

        chip.frame = CGRect(origin: .zero, size: size)
        chip.layoutSubtreeIfNeeded()
        let buttonWidth = Self.alignment(button).width
        #expect(Self.close(Self.alignment(button).maxX, size.width - 4))

        chip.frame.size.width = size.width - 40
        chip.layoutSubtreeIfNeeded()
        #expect(Self.close(Self.alignment(button).width, buttonWidth), "Take over kept its width")
        #expect(Self.close(Self.alignment(button).maxX, chip.frame.width - 4), "and its 4 pt from the trailing edge")
    }

    @Test func rightToLeftPutsTakeOverAtTheLeftEdge() throws {
        _ = NSApplication.shared
        let chip = TerminalSizedForChip()
        chip.userInterfaceLayoutDirection = .rightToLeft
        chip.show(TerminalSizedFor(deviceName: nil, deviceKind: "mac", sameDevice: true, grid: TerminalGridSize(columns: 150, rows: 42)))
        let button = try #require(chip.subviews.compactMap { $0 as? NSButton }.first)
        chip.frame = CGRect(origin: .zero, size: chip.fittingSize)
        chip.layoutSubtreeIfNeeded()
        #expect(Self.close(Self.alignment(button).minX, 4))
        let label = try #require(Self.label(in: chip))
        #expect(Self.close(Self.alignment(label).maxX, chip.frame.width - 12))
    }

    @Test func theCopyModeBadgeStaysInTheTopTrailingCornerAsTheTerminalResizes() {
        _ = NSApplication.shared
        let host = NSView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        let badge = TerminalCopyModeBadge()
        #expect(Self.usesFrames(badge))
        badge.pin(toTopTrailingOf: host)
        host.addSubview(badge)
        #expect(badge.frame.size == badge.chipLayout.preferredSize)
        #expect(badge.frame.maxX == 392)
        #expect(badge.frame.maxY == 292)
        host.setFrameSize(CGSize(width: 600, height: 500))
        #expect(badge.frame.maxX == 592)
        #expect(badge.frame.maxY == 492)
    }

    @Test func theCopyModeBadgeFindsTheTopOfAFlippedOrRightToLeftTerminal() {
        _ = NSApplication.shared
        let flipped = FlippedView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        let badge = TerminalCopyModeBadge()
        badge.pin(toTopTrailingOf: flipped)
        #expect(badge.frame.minY == 8)
        let rtl = NSView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        rtl.userInterfaceLayoutDirection = .rightToLeft
        badge.pin(toTopTrailingOf: rtl)
        #expect(badge.frame.minX == 8)
    }

    @Test func theFindBarFramesItsPillAtThePillsOwnSize() throws {
        _ = NSApplication.shared
        let host = TerminalHostView(mainWork: MainWorkScheduler(budget: MainFrameBudget()))
        let find = TerminalFindController()
        find.open(takeFocus: false)
        host.attachFind(find)
        let bar = try #require(host.subviews.compactMap { $0 as? TerminalFindBarView }.first)
        #expect(Self.usesFrames(bar))
        #expect(bar.fittingSize == bar.pill.fittingSize)
        bar.frame = CGRect(x: 0, y: 0, width: 260, height: bar.fittingSize.height)
        bar.layoutSubtreeIfNeeded()
        #expect(bar.pill.frame == bar.bounds)
    }
}

private final class FlippedView: NSView {
    nonisolated override var isFlipped: Bool { true }
}
