import AppKit
import CmuxHomeCore
import CmuxNextDesign
import CmuxNextDesignTokens
@testable import CmuxNextHome
@testable import CmuxNextHomeModel
import CmuxNextPages
import CmuxNextSettings
import CmuxNextTestSupport
import Foundation
import Testing

/// The React Messages list's app facts (round 6, the list package): what the native `HomeSidebarView`
/// drew from its model and the page now reads from `cmux.home.messages.list` (the rows' Chief tags, the
/// Cloud note, the teammates, the header's sizes), the list width kept per window, and the header band
/// that moves the window.
@MainActor
struct HomeMessagesR6ListTests {
    static let me = HomeNewMessageTests.me
    static let ada = HomeNewMessageTests.ada
    static let grace = HomeNewMessageTests.grace
    static let base = SidebarRowTokens.Base(rowHeight: 24, space1: 2, space2: 4, space3: 6, space4: 8,
                                            cornerRadius: 6, body: 13, caption: 11)

    static func object(_ value: JSONValue, _ key: String) -> [String: JSONValue] { value.objectValue?[key]?.objectValue ?? [:] }

    // MARK: Gap H, G, E: the stream's value

    /// Each Chief row's tag ("Main · Cloud", "This Mac", "cmux20") goes to the page by conversation;
    /// a DM has none (HomeSidebarView.entry's `item.listBadge ?? item.backendBadge`).
    @Test func theStreamCarriesEachChiefRowsTag() {
        let model = HomeSidebarModel(rows: HomeChiefRosterTests.rows, pins: HomePins(), me: Self.me, chiefRoster: HomeChiefRosterTests.roster())
        let value = HomeMessagesListFeed.json(model: model, people: [], header: .standard)
        let badges = Self.object(value, "badges")
        #expect(badges[HomeChiefRosterTests.hosted.rawValue]?.stringValue == HomeModelStrings.mainChief + " \u{00B7} " + HomeChiefPlace.cloud.label)
        #expect(badges[HomeChiefRosterTests.local.rawValue]?.stringValue == HomeModelStrings.placeThisMac)
        #expect(badges[HomeChiefRosterTests.ada.rawValue] == nil, "a DM has no tag")
    }

    /// The quiet line under the list (Cloud unreachable) and the teammates with no DM yet ride along.
    @Test func theStreamCarriesTheNoteAndTheTeammates() {
        let rows = [HomeNewMessageTests.row("dm-grace", [Self.grace.id])]
        var model = HomeSidebarModel(rows: rows, pins: HomePins(), me: Self.me, contacts: HomeNewMessageTests.contacts)
        model.cloudState = "unavailable"
        let people = HomeSidebarModel.withoutDM(HomeNewMessageTests.contacts, rows: rows)
        let value = HomeMessagesListFeed.json(model: model, people: people, header: .standard)
        #expect(value.objectValue?["note"]?.stringValue == HomeConversationStrings.cloudNote("unavailable"))
        let teammates = value.objectValue?["teammates"]?.arrayValue?.compactMap { $0.objectValue?["id"]?.stringValue }
        #expect(teammates == [Self.ada.id.rawValue], "the team member with no DM is a row; a connection and a Chief are not")
        #expect(teammates?.contains(Self.grace.id.rawValue) == false, "a DM peer is no teammate row")
        let ids = value.objectValue?["people"]?.arrayValue?.compactMap { $0.objectValue?["id"]?.stringValue } ?? []
        #expect(!ids.contains(Self.grace.id.rawValue) && ids.contains(Self.ada.id.rawValue))
        let reachable = HomeSidebarModel(rows: rows, pins: HomePins(), me: Self.me)
        #expect(HomeMessagesListFeed.json(model: reachable, people: [], header: .standard).objectValue?["note"] == .null)
    }

    // MARK: Gap B: the header's sizes

    /// Compact with the default text keeps today's sizes (HomeHeaderDensityTests: 30/24/6/10); a bigger
    /// density or text size grows the circle, the chip and the text; Expanded is Comfortable's.
    @Test func theHeaderFollowsDensityAndTextSize() {
        let metrics = { (d: SidebarDensity, t: SidebarTextSize) in
            HomeMessagesHeaderMetrics(tokens: SidebarRowTokens(density: d, textSize: t, base: Self.base))
        }
        #expect(metrics(.compact, .standard) == .standard)
        #expect(HomeMessagesHeaderMetrics.standard.side == 30 && HomeMessagesHeaderMetrics.standard.chipHeight == 24)
        let big = metrics(.comfortable, .larger)
        #expect(big.side > 30 && big.chipHeight > 24 && big.chipPadding > 10 && big.textStep > 0)
        #expect(metrics(.expanded, .large) == metrics(.comfortable, .large))
        let header = Self.object(HomeMessagesListFeed.json(model: nil, people: [], header: big), "header")
        #expect(header["side"]?.doubleValue == Double(big.side))
    }

    // MARK: Gap K: the width per window

    /// The width is kept per window key, saved only when the page says (a drag), and the divider's
    /// double-click (null) goes back to the standard width; another key keeps its own.
    @Test func theWidthIsKeptPerWindowKey() async throws {
        let defaults = try #require(UserDefaults(testSuiteName: "HomeMessagesR6ListTests.\(UUID().uuidString)"))
        let widths = HomeSidebarWidth(defaults: defaults)
        let dock = HomeMessagesListFeed(widths: widths, widthKey: { "home-dock" })
        let tab = HomeMessagesListFeed(widths: widths, widthKey: { "home-tab" })
        let context = PageCallContext(page: "cmux.home-messages")
        #expect(try await dock.call(HomeMessagesListFeed.widthPrefix + "load", params: .object([:]), context: context).objectValue?["width"] == .null)
        _ = try await dock.call(HomeMessagesListFeed.widthPrefix + "save", params: .object(["width": .number(240)]), context: context)
        #expect(try await dock.call(HomeMessagesListFeed.widthPrefix + "load", params: .object([:]), context: context).objectValue?["width"]?.doubleValue == 240)
        #expect(try await tab.call(HomeMessagesListFeed.widthPrefix + "load", params: .object([:]), context: context).objectValue?["width"] == .null)
        _ = try await dock.call(HomeMessagesListFeed.widthPrefix + "save", params: .object(["width": .null]), context: context)
        #expect(widths.width(window: "home-dock") == nil)
    }

    // MARK: Gap C: the header band moves the window

    /// The band's empty space drags (and a double-click runs the titlebar action, the same path);
    /// its controls take the press; below the band nothing drags but the top edge.
    @Test func theHeaderBandDragsButNotItsControls() async throws {
        let strip = HomeWindowDragStrip()
        let defaults = try #require(UserDefaults(testSuiteName: "HomeMessagesR6ListTests.\(UUID().uuidString)"))
        let feed = HomeMessagesListFeed(widths: HomeSidebarWidth(defaults: defaults), widthKey: { "k" })
        feed.onDragBand = { strip.setBand($0, controls: $1) }
        let rect = { (x: Double, y: Double, w: Double, h: Double) in
            JSONValue.object(["x": .number(x), "y": .number(y), "width": .number(w), "height": .number(h)])
        }
        _ = try await feed.call(HomeMessagesListFeed.dragBandOp, params: .object([
            "band": rect(0, 0, 320, 52), "controls": .array([rect(10, 11, 268, 30), rect(284, 11, 30, 30)]),
        ]), context: PageCallContext(page: "cmux.home-messages"))
        #expect(strip.frame(in: CGRect(x: 0, y: 0, width: 1000, height: 700)) == CGRect(x: 0, y: 0, width: 1000, height: 52))
        #expect(strip.drags(at: CGPoint(x: 5, y: 30)), "the band's empty edge drags")
        #expect(!strip.drags(at: CGPoint(x: 100, y: 25)), "the search field takes the press")
        #expect(!strip.drags(at: CGPoint(x: 300, y: 25)), "the Unread toggle takes the press")
        #expect(!strip.drags(at: CGPoint(x: 600, y: 30)), "the transcript's header is not the list's band")
        #expect(strip.drags(at: CGPoint(x: 600, y: 3)), "the page's top edge still drags")
    }
}
