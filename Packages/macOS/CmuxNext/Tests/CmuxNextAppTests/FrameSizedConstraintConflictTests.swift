import AppKit
import CmuxNextDesign
@testable import CmuxNextHome
@testable import CmuxNextHomeModel
@testable import CmuxNextTerminal
import Foundation
import OSLog
import Testing

/// Views their owner sizes by frame, whose parts carry fixed sizes: the engine solves the parts before the owner gives the
/// view its frame, so with required edges every first pass broke a constraint and logged "Unable to simultaneously satisfy
/// constraints" on the main thread, with a state dump. A NIGHTLY with 231 workspaces logged 157 in 30 minutes (Home
/// first-run panel: hero, starters and Switching card against its 0 x 0 stack; a terminal's in-between mark against its
/// banner's built zero frame). The final frames are right either way, so this reads what AppKit logged for these views.
@MainActor @Suite(.serialized) struct FrameSizedConstraintConflictTests {
    private static let keys = HomeSwitchKeys(tabByNumber: "⌃1…9", workspaceByNumber: "⌘1…9", nextPreviousTab: "⇧⌘[ ⇧⌘]",
                                             nextPreviousWorkspace: nil, focusBackForward: "⌥⌘, ⌥⌘.")

    /// The address AppKit prints for `view` in a constraint's description (`Type:0x…`).
    private static func address(_ view: NSView) -> String {
        String(format: "%p", Unmanaged.passUnretained(view).toOpaque())
    }

    /// AppKit's "Unable to simultaneously satisfy constraints" messages since `start` that name one of `views`.
    private static func conflicts(since start: Date, naming views: [NSView]) throws -> [String] {
        let store = try OSLogStore(scope: .currentProcessIdentifier)
        let entries = try store.getEntries(at: store.position(date: start),
                                           matching: NSPredicate(format: "subsystem == 'com.apple.AppKit' AND category == 'Layout'"))
        let addresses = views.map(address)
        return entries.compactMap { $0 as? OSLogEntryLog }.map(\.composedMessage).filter { message in
            message.contains("Unable to simultaneously satisfy constraints")
                && addresses.contains { message.contains(":\($0)") }
        }
    }

    /// The check sees a conflict when there is one, so an empty answer below means none was logged.
    @Test func theCheckSeesAConflict() throws {
        let start = Date().addingTimeInterval(-1)
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        let part = NSView()
        part.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(part)
        NSLayoutConstraint.activate([
            part.widthAnchor.constraint(equalToConstant: 10), part.widthAnchor.constraint(equalToConstant: 20),
            part.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            part.topAnchor.constraint(equalTo: container.topAnchor), part.heightAnchor.constraint(equalToConstant: 10),
        ])
        container.layoutSubtreeIfNeeded()
        #expect(try !Self.conflicts(since: start, naming: [part]).isEmpty, "SETUP: a width of 10 and of 20 is logged")
    }

    @Test func aNewFirstRunPanelLogsNoConflict() throws {
        let start = Date().addingTimeInterval(-1)
        let panel = HomeFirstRunView(frame: NSRect(x: 0, y: 0, width: 600, height: 800))
        panel.hero.setAvatar(picture: nil, text: nil, name: "Chief")
        panel.setShortcuts(terminal: "⌘T", agent: "⇧⌘N", switching: Self.keys)
        panel.starters.setPrompts(["Fix the failing test in todo-app", "Review sample/todo#42"])
        panel.needsLayout = true
        panel.layoutSubtreeIfNeeded()
        let parts: [NSView] = [panel.hero, panel.starters, panel.switchCard, panel.intro] + panel.rows
        #expect(try Self.conflicts(since: start, naming: parts) == [])
        // The resting column is unchanged: 340 pt wide, every part shown at its full width.
        #expect(panel.hero.frame.width == HomeFirstRunView.maxWidth)
        #expect(panel.switchCard.frame.width == HomeFirstRunView.maxWidth)
        #expect(!panel.switchCard.isHiddenOrHasHiddenAncestor)
    }

    @Test func aPanelTooShortForItsPartsLogsNoConflict() throws {
        let start = Date().addingTimeInterval(-1)
        let panel = HomeFirstRunView(frame: NSRect(x: 0, y: 0, width: 600, height: 120))
        panel.hero.setAvatar(picture: nil, text: nil, name: "Chief")
        panel.setShortcuts(terminal: "⌘T", agent: "⇧⌘N", switching: Self.keys)
        panel.needsLayout = true
        panel.layoutSubtreeIfNeeded()
        panel.setFrameSize(NSSize(width: 30, height: 20))
        panel.needsLayout = true
        panel.layoutSubtreeIfNeeded()
        #expect(try Self.conflicts(since: start, naming: [panel.hero, panel.starters, panel.switchCard] + panel.rows) == [])
    }

    @Test func aBannerShowingItsMarkLogsNoConflict() throws {
        let start = Date().addingTimeInterval(-1)
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let banner = TerminalStatusBanner()
        host.addSubview(banner)
        // The mark shows while the banner is still at its built zero frame, before the host places it.
        banner.show("Restoring…", inBetween: true, fadeIn: false)
        host.layoutSubtreeIfNeeded()
        let mark = try #require(banner.subviews.first { $0 is StatusIndicatorView })
        #expect(try Self.conflicts(since: start, naming: [mark]) == [])
        // Placed at its fitting size, the mark keeps its side and its 4 pt pad.
        #expect(banner.fittingSize == NSSize(width: TerminalStatusBanner.markSide + 8, height: TerminalStatusBanner.markSide + 8))
        banner.frame = NSRect(origin: .zero, size: banner.fittingSize)
        host.layoutSubtreeIfNeeded()
        #expect(mark.frame.size == NSSize(width: TerminalStatusBanner.markSide, height: TerminalStatusBanner.markSide))
    }
}
