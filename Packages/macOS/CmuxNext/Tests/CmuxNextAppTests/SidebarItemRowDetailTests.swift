import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import Testing

/// Lawrence's flat remote rows (db986014) give each remote chat its machine's name, but they put it in
/// `caption`, which only a tile draws: on a row nothing said which machine a chat ran on, so remote chats
/// read as local ones. A row now draws `detail` after its title, on the same line and in quieter ink.
@MainActor @Suite(.serialized)
struct SidebarItemRowDetailTests {
    static func row(_ info: SidebarItemInfo, style: SidebarItemRowView.Style, width: CGFloat = 260) -> SidebarItemRowView {
        _ = NSApplication.shared
        let view = SidebarItemRowView(frame: NSRect(x: 0, y: 0, width: width, height: 28))
        view.configure(info, style: style)
        view.layoutSubtreeIfNeeded()
        return view
    }

    static func remote(_ title: String = "Review the peer list") -> SidebarItemInfo {
        var info = SidebarItemInfo(title: title, symbol: "bubble.left", brand: "codex")
        info.detail = "linux-box"
        return info
    }

    @Test(arguments: [SidebarItemRowView.Style.builtIn, .list])
    func aRowDrawsItsMachineAfterItsTitle(_ style: SidebarItemRowView.Style) {
        let view = Self.row(Self.remote(), style: style)
        #expect(view.detailText == "linux-box")
        #expect(view.detailFrame.width > 0 && view.detailFrame.minX >= view.titleFrame.maxX)
        #expect(view.detailFrame.maxX <= view.bounds.width)
        #expect(view.accessibilityLabel() == "Review the peer list, linux-box")
    }

    /// With room to spare neither label is cut: each frame holds its text and its side padding.
    @Test func roomyRowsCutNeither() {
        let view = Self.row(Self.remote("Notes"), style: .builtIn, width: 300)
        #expect(view.titleFrame.width >= ceil(view.title.naturalSize.width), "title frame \(view.titleFrame.width) is narrower than its text")
        #expect(view.detailFrame.width >= ceil(view.detail.naturalSize.width), "detail frame \(view.detailFrame.width) is narrower than its text")
    }

    /// A working remote chat's mark turns (the spinner rule, cmux#22826): the arc runs its spin, never
    /// a still or breathing dot. A capture cannot show this: a headless capture window is occluded, so
    /// the indicator draws its still mark there.
    @Test func aWorkingRowSpins() throws {
        // Motion pinned on (as MotionMasterSwitchSurfaceTests does), so the host's Reduce Motion or a
        // saved switch cannot still the arc; the override's notice re-reads the indicator config.
        let design = DesignSettings.shared
        let (oldEnabled, oldDisabled) = (design.animationsEnabled, design.disabledAnimationCategories)
        design.animationsEnabled = true
        design.disabledAnimationCategories = []
        Motion.reduceMotionOverride = false
        defer {
            design.animationsEnabled = oldEnabled
            design.disabledAnimationCategories = oldDisabled
            Motion.reduceMotionOverride = nil
        }
        let config = StatusIndicatorConfig.current
        try #require(config.animatesLoops && config.iconSet == .codex && config.workingLook == .spinner && !config.isStatic,
                     "the indicator settings are not the shipped spinner (\(config.iconSet), \(config.workingLook))")
        var info = Self.remote()
        info.activity = .working
        let view = Self.row(info, style: .builtIn)
        let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView?.addSubview(view)
        view.activity.isWindowVisible = true
        view.layoutSubtreeIfNeeded()
        #expect(view.activity.indicator.runningAnimation == .spin,
                "a working row runs \(String(describing: view.activity.indicator.runningAnimation))")
    }

    /// A row with an unread dot draws its status after the text, not on the column: it follows the
    /// machine name instead of covering it.
    @Test func theStatusFollowsTheMachineName() {
        var info = Self.remote()
        info.activity = .waiting
        info.unreadDot = true
        let view = Self.row(info, style: .builtIn)
        #expect(view.activity.frame.width > 0, "the waiting mark does not draw")
        #expect(view.activity.frame.minX >= view.detailFrame.maxX,
                "the status at \(view.activity.frame.minX) covers the machine name ending at \(view.detailFrame.maxX)")
    }

    /// A long title truncates first: the machine keeps room to show.
    @Test func aLongTitleLeavesTheMachineRoom() {
        let view = Self.row(Self.remote(String(repeating: "Prune DerivedData on the minis ", count: 4)), style: .builtIn, width: 220)
        #expect(view.detailFrame.width >= 30, "the machine name was squeezed to \(view.detailFrame.width) pt")
        #expect(view.titleFrame.maxX <= view.detailFrame.minX)
    }

    /// Tiles, icons and chips draw no detail, and a row without one lays out as before.
    @Test func otherLooksAndPlainRowsDrawNone() {
        for style in [SidebarItemRowView.Style.tile, .icon, .chip, .favorite] {
            let view = Self.row(Self.remote(), style: style)
            #expect(view.detailText == nil, "\(style) drew a detail")
            // Where no detail draws, VoiceOver still names the machine.
            #expect(view.accessibilityLabel() == "Review the peer list, linux-box", "\(style) lost its machine")
        }
        // A tile keeps the chat's title on its face and names the machine in its tooltip.
        let tile = Self.row(Self.remote(), style: .favorite)
        #expect(tile.titleText == "Review the peer list")
        #expect(tile.themedToolTip == "Review the peer list, linux-box")
        let plain = Self.row(SidebarItemInfo(title: "App Store", symbol: "bag", caption: "Apps"), style: .builtIn)
        #expect(plain.detailText == nil && plain.titleText == "App Store")
        #expect(plain.accessibilityLabel() == "App Store")
    }
}
