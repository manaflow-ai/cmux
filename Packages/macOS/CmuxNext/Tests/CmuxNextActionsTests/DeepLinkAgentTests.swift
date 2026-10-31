import CmuxNextActions
import Foundation
import Testing

/// `cmux://agent/<harness>/<harnessSessionId>` (hq#2555, agent provenance): an address of an
/// outside agent's session by the harness's own id. It parses only in its exact shape, keeps
/// `host`/`name` as display hints only when they are short tokens, and never changes how the
/// other links parse or format.
struct DeepLinkAgentTests {
    private func parse(_ text: String, scheme: String = "cmux") -> DeepLink? {
        DeepLink.parse(URL(string: text)!, scheme: scheme)
    }

    @Test func anAgentLinkParsesToItsHarnessAndSession() {
        let link = parse("cmux://agent/claude/0f3c2a91-7d4e-4b8a-9c11-2e5f6a7b8c9d")
        #expect(link == DeepLink(.agent(harness: "claude", session: "0f3c2a91-7d4e-4b8a-9c11-2e5f6a7b8c9d")))
        #expect(link?.hostHint == nil)
        #expect(link?.nameHint == nil)
    }

    @Test func hintsAreKeptAndFormattedBack() throws {
        let text = "cmux://agent/codex/019a-thread_7?host=build-mac&name=Lanternfish"
        let link = try #require(parse(text))
        #expect(link.target == .agent(harness: "codex", session: "019a-thread_7"))
        #expect(link.hostHint == "build-mac")
        #expect(link.nameHint == "Lanternfish")
        #expect(link.url(scheme: "cmux")?.absoluteString == text)
    }

    @Test(arguments: [
        DeepLink(.agent(harness: "claude", session: "s1")),
        DeepLink(.agent(harness: "opencode", session: "ses_01.a-b")),
        DeepLink(.agent(harness: "gemini", session: "x"), hostHint: "build-mac"),
        DeepLink(.agent(harness: "pi", session: "x"), nameHint: "Lanternfish"),
        DeepLink(.agent(harness: "amp", session: "x"), machine: "machine_0123456789abcdef0123456789abcdef",
                 hostHint: "h", nameHint: "n"),
    ])
    func formattedAgentLinksParseBackToTheSameLink(_ link: DeepLink) throws {
        let url = try #require(link.url(scheme: "cmux-dev"))
        #expect(DeepLink.parse(url, scheme: "cmux-dev") == link)
    }

    @Test(arguments: [
        "cmux://agent/claude",  // one segment
        "cmux://agent/claude/s1/extra",  // three segments
        "cmux://agent",  // no segments
        "cmux://agent/Claude/s1",  // a harness is lowercase
        "cmux://agent/clau_de/s1",  // a harness is letters, digits and -
        "cmux://agent/claude/s%201",  // a session is a token
        "cmux://agent/claude/s1#turn-t1",  // no fragment
        "cmux://agent/claude/s1#x",
        "other-app://agent/claude/s1",  // another build's scheme
        "cmux://user@agent/claude/s1",
        "cmux://agent:8080/claude/s1",
        "cmux://agent/claude/..",  // a dots-only session collapses as a path
        "cmux://agent/claude/.",
    ])
    func malformedAgentLinksAreRefused(_ text: String) {
        #expect(parse(text) == nil)
    }

    @Test func aTooLongSessionOrHarnessIsRefused() {
        #expect(parse("cmux://agent/claude/" + String(repeating: "a", count: 257)) == nil)
        #expect(parse("cmux://agent/claude/" + String(repeating: "a", count: 256)) != nil)
        #expect(parse("cmux://agent/claude/session:with:colon") != nil)
        #expect(parse("cmux://agent/" + String(repeating: "a", count: 65) + "/s1") == nil)
        #expect(DeepLink(.agent(harness: "claude", session: String(repeating: "a", count: 256))).url(scheme: "cmux") != nil)
        #expect(DeepLink(.agent(harness: "claude", session: String(repeating: "a", count: 257))).url(scheme: "cmux") == nil)
        #expect(DeepLink(.agent(harness: "Claude", session: "s1")).url(scheme: "cmux") == nil)
        #expect(DeepLink(.agent(harness: "claude", session: "...")).url(scheme: "cmux") == nil)
    }

    @Test(arguments: [
        "cmux://agent/claude/s1?host=build%20mac&name=Lanternfish",
        "cmux://agent/claude/s1?host=&name=",
        "cmux://agent/claude/s1?host=" + String(repeating: "h", count: 65),
        "cmux://agent/claude/s1?host=a/b",
        "cmux://agent/claude/s1?name=%3Cscript%3E",
        "cmux://agent/claude/s1?host=..",
    ])
    func malformedHintsAreDroppedNotTheLink(_ text: String) throws {
        let link = try #require(parse(text))
        #expect(link.target == .agent(harness: "claude", session: "s1"))
        #expect(link.hostHint == nil)
        // A well-formed hint beside a malformed one is kept.
        #expect(link.nameHint == (text.contains("name=Lanternfish") ? "Lanternfish" : nil))
    }

    @Test func hintsNeverRideOnOtherLinks() throws {
        let tab = "tab_0123456789abcdef0123456789abcdef"
        let link = try #require(parse("cmux://tab/\(tab)?host=build-mac&name=Lanternfish"))
        #expect(link == DeepLink(.tab(tab)))
        #expect(link.url(scheme: "cmux")?.absoluteString == "cmux://tab/\(tab)")
        // A hint on a link that has none is not well formed: it would not parse back.
        #expect(DeepLink(.tab(tab), hostHint: "build-mac").url(scheme: "cmux") == nil)
    }

    @Test(arguments: [
        "cmux://workspace/ws_0123456789abcdef0123456789abcdef",
        "cmux://pane/pane_0123456789abcdef0123456789abcdef",
        "cmux://tab/tab_0123456789abcdef0123456789abcdef?machine=machine_0123456789abcdef0123456789abcdef",
        "cmux://session/ses-01.example_a",
        "cmux://session/ses-01.example_a#turn-turn_7",
        "cmux://chief/2e448bc2/session/01a12408-f0a2",
        "cmux://workspace/6B1F0A52-6C0F-4B44-9A43-0F4C2C0E6D11?stable_workspace_id=0E3C1F8A-1A2B-4C3D-8E9F-0A1B2C3D4E5F",
    ])
    func existingLinksFormatExactlyAsBefore(_ text: String) throws {
        let link = try #require(parse(text))
        #expect(link.hostHint == nil && link.nameHint == nil)
        #expect(link.url(scheme: "cmux")?.absoluteString == text)
    }

    // MARK: Which tab an agent link opens

    private let session = "0f3c2a91-7d4e-4b8a-9c11-2e5f6a7b8c9d"

    @Test func theChatTabThatAdoptedTheSessionWins() {
        let terminals = [DeepLink.AgentCandidate(tab: "term-1", harness: "claude", session: session)]
        #expect(DeepLink.agentTab(harness: "claude", session: session, adopted: "chat-1", terminals: terminals) == "chat-1")
    }

    @Test func elseTheTerminalRunningThatSessionOpens() {
        let terminals = [
            DeepLink.AgentCandidate(tab: "term-0", harness: "claude", session: "other"),
            DeepLink.AgentCandidate(tab: "term-1", harness: nil, session: nil),
            DeepLink.AgentCandidate(tab: "term-2", harness: "claude", session: session),
        ]
        #expect(DeepLink.agentTab(harness: "claude", session: session, adopted: nil, terminals: terminals) == "term-2")
    }

    @Test func aTerminalOfAnotherHarnessWithTheSameIdDoesNotOpen() {
        let terminals = [
            DeepLink.AgentCandidate(tab: "term-1", harness: "codex", session: session),
            DeepLink.AgentCandidate(tab: "term-2", harness: "Claude", session: session),
        ]
        #expect(DeepLink.agentTab(harness: "claude", session: session, adopted: nil, terminals: terminals) == "term-2")
        #expect(DeepLink.agentTab(harness: "gemini", session: session, adopted: nil, terminals: terminals) == nil)
    }

    @Test func aTerminalWhoseHarnessIsUnknownStillMatchesBySession() {
        let terminals = [DeepLink.AgentCandidate(tab: "term-1", harness: nil, session: session)]
        #expect(DeepLink.agentTab(harness: "claude", session: session, adopted: nil, terminals: terminals) == "term-1")
    }

    @Test func aSubagentsAgentTypeIsNoHarness() {
        let terminals = [
            DeepLink.AgentCandidate(tab: "term-1", harness: "general-purpose", session: session),
            DeepLink.AgentCandidate(tab: "term-2", harness: "claude-code", session: session),
        ]
        #expect(DeepLink.agentTabs(harness: "claude", session: session, adopted: nil, terminals: terminals) == ["term-2", "term-1"])
        #expect(DeepLink.agentTabs(harness: "codex", session: session, adopted: nil, terminals: terminals) == ["term-1"])
    }

    @Test func theHarnessesTerminalsComeBeforeUnnamedOnes() {
        let terminals = [
            DeepLink.AgentCandidate(tab: "term-1", harness: nil, session: session),
            DeepLink.AgentCandidate(tab: "term-2", harness: "claude", session: session),
            DeepLink.AgentCandidate(tab: "term-3", harness: "codex", session: session),
        ]
        #expect(DeepLink.agentTabs(harness: "claude", session: session, adopted: "chat-1", terminals: terminals)
            == ["chat-1", "term-2", "term-1"])
    }

    @Test func nothingReachableMeansNoTab() {
        let terminals = [DeepLink.AgentCandidate(tab: "term-1", harness: "claude", session: "other")]
        #expect(DeepLink.agentTab(harness: "claude", session: session, adopted: nil, terminals: terminals) == nil)
        #expect(DeepLink.agentTab(harness: "claude", session: session, adopted: nil, terminals: []) == nil)
    }

    @Test func theDaemonsHarnessSessionsMatchLikeCandidates() {
        let sessions: [(tab: String, agent: String?, session: String)] = [("term-1", "codex", session), ("term-2", nil, session)]
        #expect(DeepLink.agentTab(harness: "claude", session: session, adopted: nil, harnessSessions: sessions) == "term-2")
    }
}
