@testable import CmuxNextBridge
@testable import CmuxNextDaemon
import CmuxNextDesign
import CmuxNextIcons
@testable import CmuxNextSidebar
import Foundation
import Testing

/// Leo 2026-11-19: "what was everybody doing with the tiny weather space and the example domain
/// space in cmux next on cosmic-gray?" / "acpmux should expose these a lot better". The daemon
/// records who made each workspace (`extra.created_by`: kind, acpmux session id and name, host,
/// purpose); the hover card says it for an agent or a script, and nothing new for the person.
@MainActor @Suite(.serialized) struct WorkspaceHoverCardOriginTests {
    static let now = Date(timeIntervalSince1970: 1_800_000_000)
    static let full = #"{"created_by":{"kind":"agent","workspace":"ws_lead","session":"5f2c9a7e-81d4-4b6a","session_name":"desktop-helper","host":"dev-mini","purpose":"Demo project for the weather widget"}}"#

    static func detail(_ origin: SidebarWorkspaceOrigin?) -> SidebarWorkspaceDetail {
        var detail = SidebarWorkspaceDetail()
        detail.origin = origin
        return detail
    }

    @Test func theCreatorDecodesWithEveryFieldOptional() throws {
        let object: JSONValue = .object([
            "kind": .string("agent"), "workspace": .string("ws_lead"), "session": .string("s1"),
            "session_name": .string("desktop-helper"), "host": .string("dev-mini"), "purpose": .string("Demo project"),
        ])
        let creator = try #require(WorkspaceCreator(object))
        #expect(creator == WorkspaceCreator(kind: .agent, workspace: "ws_lead", session: "s1", sessionName: "desktop-helper",
                                            host: "dev-mini", purpose: "Demo project"))
        #expect(WorkspaceCreator(.object(["kind": .string("script")])) == WorkspaceCreator(kind: .script))
        // A kind from a newer daemon is kept, not dropped; blank fields read as unset.
        let newer = try #require(WorkspaceCreator(.object(["kind": .string("robot"), "host": .string("  ")])))
        #expect(newer.kind == .other("robot") && newer.host == nil)
        #expect(WorkspaceCreator(.object(["host": .string("dev-mini")])) == nil, "no kind")
        #expect(WorkspaceCreator(.string("agent")) == nil)
        #expect(WorkspaceCreator(nil) == nil)
    }

    /// The session snapshot's `extra.created_by` reaches the row's detail and its hover card.
    @Test func anAgentsWorkspaceSaysWhoMadeItAndWhy() throws {
        let row = try WorkspaceNotesTests.row(extra: Self.full)
        let origin = try #require(row.detail.origin)
        #expect(origin.kind == .agent && origin.sessionName == "desktop-helper" && origin.host == "dev-mini")
        let card = WorkspaceHoverCardContent.make(row, machine: nil, now: Self.now)
        let lines = card.facts.filter { [WorkspaceHoverCardOrigin.creatorKind, WorkspaceHoverCardOrigin.purposeKind].contains($0.kind) }
        #expect(lines.map(\.text) == ["desktop-helper on dev-mini", "Demo project for the weather widget"])
        #expect(lines.allSatisfy { !$0.isMessage }, "the origin is metadata, in the secondary ink")
    }

    @Test func thePersonsWorkspaceShowsNothingNew() throws {
        for extra in [#"{"created_by":{"kind":"person","host":"dev-mini","purpose":"Mine"}}"#, "{}",
                      #"{"created_by":{"kind":"script"}}"#, #"{"created_by":{"kind":"robot","session_name":"x"}}"#] {
            let row = try WorkspaceNotesTests.row(extra: extra)
            #expect(row.detail.origin == nil, "\(extra)")
            let card = WorkspaceHoverCardContent.make(row, machine: nil, now: Self.now)
            #expect(!card.facts.contains { $0.kind == WorkspaceHoverCardOrigin.creatorKind || $0.kind == WorkspaceHoverCardOrigin.purposeKind })
        }
        for style in WorkspaceHoverCardOrigin.Style.allCases {
            #expect(WorkspaceHoverCardOrigin.facts(Self.detail(nil), style: style).isEmpty)
        }
    }

    @Test func eachStyleWordsTheOrigin() {
        let agent = Self.detail(SidebarWorkspaceOrigin(kind: .agent, sessionName: "desktop-helper", sessionID: "5f2c9a7e-81d4",
                                                       host: "dev-mini", purpose: "Demo project for the weather widget"))
        #expect(WorkspaceHoverCardOrigin.facts(agent, style: .line).map(\.text)
            == ["desktop-helper on dev-mini", "Demo project for the weather widget"])
        #expect(WorkspaceHoverCardOrigin.facts(agent, style: .byline).map(\.text)
            == ["Made by desktop-helper · dev-mini: Demo project for the weather widget"])
        let footer = WorkspaceHoverCardOrigin.facts(agent, style: .footer)
        #expect(footer.map(\.text) == ["Demo project for the weather widget — desktop-helper@dev-mini"])
        #expect(footer.first?.ink == .tertiary)
        #expect(WorkspaceHoverCardOrigin.shipped == .line && !WorkspaceHoverCardOrigin.isFooter(.line))
    }

    /// No session name: the start of the session id names the creator; no purpose: the creator alone.
    @Test func aMissingNameOrPurposeFallsBack() {
        let agent = Self.detail(SidebarWorkspaceOrigin(kind: .agent, sessionID: "5f2c9a7e-81d4-4b6a", host: "dev-mini"))
        #expect(WorkspaceHoverCardOrigin.facts(agent, style: .line).map(\.text) == ["5f2c9a7e on dev-mini"])
        #expect(WorkspaceHoverCardOrigin.facts(agent, style: .byline).map(\.text) == ["Made by 5f2c9a7e · dev-mini"])
        #expect(WorkspaceHoverCardOrigin.facts(agent, style: .footer).map(\.text) == ["— 5f2c9a7e@dev-mini"])

        let script = Self.detail(SidebarWorkspaceOrigin(kind: .script, purpose: "Nightly smoke test\nsecond line"))
        #expect(WorkspaceHoverCardOrigin.facts(script, style: .line).map(\.text) == ["Script", "Nightly smoke test"])
        #expect(WorkspaceHoverCardOrigin.facts(script, style: .line).first?.icon == .automation)

        // A purpose that only repeats the card's title is no line of its own.
        let titled = Self.detail(SidebarWorkspaceOrigin(kind: .agent, sessionName: "desktop-helper", purpose: "Weather widget"))
        #expect(WorkspaceHoverCardOrigin.facts(titled, style: .line, title: "weather widget").map(\.text) == ["desktop-helper"])
        #expect(SidebarWorkspaceOrigin(kind: .script) == nil, "a script with nothing to say")
        #expect(SidebarWorkspaceOrigin(kind: .agent, sessionName: "  ", purpose: "") == nil)
    }

    @Test func theBridgeKeepsOnlyAnAgentOrAScript() {
        #expect(SidebarMapping.origin(WorkspaceCreator(kind: .person, host: "dev-mini")) == nil)
        #expect(SidebarMapping.origin(WorkspaceCreator(kind: .other("robot"), sessionName: "x")) == nil)
        #expect(SidebarMapping.origin(nil) == nil)
        #expect(SidebarMapping.origin(WorkspaceCreator(kind: .script, session: "s1"))?.creator == "s1")
    }
}
