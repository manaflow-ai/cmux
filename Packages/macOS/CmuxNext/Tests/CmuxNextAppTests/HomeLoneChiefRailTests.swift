import AppKit
import CmuxHomeCore
import CmuxNextDesign
@testable import CmuxNextHome
import CmuxNextTestSupport
import Testing

/// Visual QA of the nightly, 2026-10-21: a narrow Home column whose list holds only the Chief drew
/// the avatar-only list (33224e07f08) as a column with one lone avatar in it, an empty band beside
/// the chat. With one conversation that list takes no column: the chat gets the width and keeps
/// compose at its top-left. Two or more conversations keep the avatar-only list, and a column wide
/// enough for names keeps the list with names. Debug Settings > Home > "Avatar list for one
/// conversation" keeps the column.
@MainActor
@Suite(.closesItsWindows)
struct HomeLoneChiefRailTests {
    struct Page {
        let split: HomeSidebarSplitView
        let home: HomeSidebarView
        let window: NSWindow
        let defaults: UserDefaults
        let suite: String
        func close() {
            window.close()
            defaults.removePersistentDomain(forName: suite)
        }

        /// The list takes no column: hidden or zero wide, and the chat spans the whole split.
        var listFolded: Bool {
            (home.isHidden || home.frame.width < 0.5) && split.transcriptWidth >= split.bounds.width - 0.5
        }

        func show(chiefs: Int) {
            home.update(HomeLoneChiefRailTests.model(chiefs: chiefs))
            split.layoutSubtreeIfNeeded()
        }

        func resize(width: CGFloat) {
            window.setContentSize(NSSize(width: width, height: 600))
            split.layoutSubtreeIfNeeded()
        }
    }

    static func model(chiefs: Int) -> HomeSidebarModel {
        let rows = PerChiefAvatarTests.chiefRows((0..<chiefs).map { ("agent_chief\($0)", "Chief \($0)") })
        return HomeSidebarModel(rows: rows, pins: HomePins(), me: PerChiefAvatarTests.me.id)
    }

    /// A Home page `width` wide whose list holds `chiefs` Chiefs (400 pt leaves the list 119 pt:
    /// avatars only, `HomeSidebarWidth.clamp`).
    static func page(chiefs: Int, width: CGFloat, tunables: TunableStore? = nil) throws -> Page {
        _ = NSApplication.shared
        let suite = "cmux.tests.loneChiefRail.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let home = HomeSidebarView(frame: NSRect(x: 0, y: 0, width: 320, height: 600))
        home.update(model(chiefs: chiefs))
        let split = HomeSidebarSplitView(sidebar: home, content: NSView(), widths: HomeSidebarWidth(defaults: defaults))
        split.windowKey = { "w" }
        if let tunables { split.tunables = tunables }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 600), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = split
        split.layoutSubtreeIfNeeded()
        return Page(split: split, home: home, window: window, defaults: defaults, suite: suite)
    }

    @Test func aLoneChiefInANarrowColumnLeavesTheChatTheWholeWidth() throws {
        let p = try Self.page(chiefs: 1, width: 400)
        defer { p.close() }
        #expect(p.listFolded, "the list keeps a \(p.home.frame.width) pt column for one avatar; the chat is \(p.split.transcriptWidth) of \(p.split.bounds.width) pt")
        let compose = try #require(HomeNarrowSidebarTests.chatCompose(in: p.split), "no compose button in the chat")
        #expect(!compose.isHidden, "compose is unreachable while the list is folded")
    }

    @Test func threeConversationsKeepTheAvatarList() throws {
        let p = try Self.page(chiefs: 3, width: 400)
        defer { p.close() }
        #expect(!p.home.isHidden)
        #expect(abs(p.split.sidebarWidth - 119) < 1, "the avatar list is \(p.split.sidebarWidth) pt")
        #expect(abs(p.split.transcriptWidth - (400 - 119 - p.split.dividerThickness)) < 1)
    }

    @Test func aLoneChiefInAWideColumnKeepsTheListWithNames() throws {
        let p = try Self.page(chiefs: 1, width: 1000)
        defer { p.close() }
        #expect(!p.home.isHidden)
        #expect(abs(p.split.sidebarWidth - HomeSidebarWidth.standard) < 1, "the list is \(p.split.sidebarWidth) pt")
    }

    /// The person's own avatar-only width keeps its column, so the divider can drag it back out.
    @Test func aListDraggedToAvatarsKeepsItsColumn() throws {
        let p = try Self.page(chiefs: 1, width: 1000)
        defer { p.close() }
        p.split.setWidth(100)
        p.split.layoutSubtreeIfNeeded()
        #expect(!p.home.isHidden, "the list the person dragged to 100 pt folded away with its divider")
        #expect(abs(p.split.sidebarWidth - 100) < 1, "the list is \(p.split.sidebarWidth) pt")
    }

    @Test func theListFoldsAndComesBackAsConversationsAndWidthChange() throws {
        let p = try Self.page(chiefs: 1, width: 400)
        defer { p.close() }
        #expect(p.listFolded)
        p.show(chiefs: 2)
        #expect(!p.listFolded && !p.home.isHidden, "a second conversation leaves the list folded")
        #expect(abs(p.split.sidebarWidth - 119) < 1, "the avatar list came back \(p.split.sidebarWidth) pt wide")
        p.show(chiefs: 1)
        #expect(p.listFolded, "the list stays after the second conversation went")
        p.resize(width: 1000)
        #expect(!p.home.isHidden, "a wide column keeps the list folded")
        #expect(abs(p.split.sidebarWidth - HomeSidebarWidth.standard) < 1, "the list came back \(p.split.sidebarWidth) pt wide")
        p.resize(width: 400)
        #expect(p.listFolded, "a narrow column again keeps the lone avatar's column")
    }

    @Test func theDebugToggleKeepsTheAvatarListForOneConversation() async throws {
        let store = TunableStore()
        store.register([HomeTunables.loneConversationRail.descriptor])
        store.activate(file: nil)
        store.set(HomeTunables.loneConversationRail.key, .bool(true))
        let p = try Self.page(chiefs: 1, width: 400, tunables: store)
        defer { p.close() }
        #expect(!p.home.isHidden, "the toggle is on and the list folded")
        #expect(abs(p.split.sidebarWidth - 119) < 1, "the avatar list is \(p.split.sidebarWidth) pt")
        // Turned off in Debug Settings: the open page folds the list without a resize.
        store.set(HomeTunables.loneConversationRail.key, .bool(false))
        for _ in 0..<100 where !p.listFolded {
            await Task.yield()
            p.split.layoutSubtreeIfNeeded()
        }
        #expect(p.listFolded, "the list stays after the toggle went off")
    }
}
