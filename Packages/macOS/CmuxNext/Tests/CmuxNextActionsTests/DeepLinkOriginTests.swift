import CmuxNextActions
import Foundation
import Testing

/// Media safety R8 (leo-workspace#874): a link clicked in model output (an agent's reply, tool
/// output, an agent-message card, the Chief's transcript) only reveals what is already open. Every
/// kind of link target has a class for each origin, and a new kind without one fails here.
struct DeepLinkOriginTests {
    /// What each kind may do when opened from model output and from the person's own surfaces.
    /// A new `DeepLink.Target` case adds a `Kind`, and this table must name it.
    private static let expected: [DeepLink.Target.Kind: (modelOutput: DeepLink.Effect, person: DeepLink.Effect)] = [
        .workspace: (.revealOnly, .revealOnly),
        .pane: (.revealOnly, .revealOnly),
        .tab: (.revealOnly, .revealOrOpen),
        .session: (.revealOnly, .revealOrOpen),
        .chiefSession: (.revealOnly, .revealOnly),
        .agent: (.revealOnly, .revealOnly),
        .legacyWorkspace: (.revealOnly, .revealOnly),
        .legacyPane: (.revealOnly, .revealOnly),
        .legacySurface: (.revealOnly, .revealOnly),
    ]

    /// One target of each kind; the switch is exhaustive, so a new kind fails to compile here too.
    private static func sample(_ kind: DeepLink.Target.Kind) -> DeepLink.Target {
        let id = UUID()
        switch kind {
        case .workspace: return .workspace("ws_0123456789abcdef0123456789abcdef")
        case .pane: return .pane("pane_0123456789abcdef0123456789abcdef")
        case .tab: return .tab("tab_0123456789abcdef0123456789abcdef")
        case .session: return .session("01a12408-f0a2-79a0-8c59-cb472f5bb9aa", turn: nil)
        case .chiefSession: return .chiefSession(home: "2e448bc2", session: "01a12408")
        case .agent: return .agent(harness: "claude", session: "0f3c2a91")
        case .legacyWorkspace: return .legacyWorkspace(id, fallback: nil)
        case .legacyPane: return .legacyPane(workspace: id, pane: id)
        case .legacySurface: return .legacySurface(workspace: id, surface: id, fallbackWorkspace: nil, fallbackSurface: nil)
        }
    }

    @Test func everyKindHasAModelOutputClass() {
        let missing = DeepLink.Target.Kind.allCases.filter { Self.expected[$0] == nil }
        #expect(missing.isEmpty, "these link kinds have no model-output class: \(missing)")
        #expect(Self.expected.count == DeepLink.Target.Kind.allCases.count)
    }

    @Test(arguments: DeepLink.Target.Kind.allCases)
    func eachKindsEffectMatchesItsClass(_ kind: DeepLink.Target.Kind) throws {
        let target = Self.sample(kind)
        #expect(target.kind == kind)
        let expected = try #require(Self.expected[kind])
        #expect(target.effect(for: .modelOutput) == expected.modelOutput)
        #expect(target.effect(for: .person) == expected.person)
    }

    @Test func modelOutputNeverReopensOrCreates() {
        for kind in DeepLink.Target.Kind.allCases {
            #expect(Self.sample(kind).effect(for: .modelOutput) == .revealOnly, "\(kind) opens something from model output")
        }
    }

    @Test func aRunIsThePersonsUnlessTheAppSaysOtherwise() {
        #expect(ActionInvocation().linkOrigin == .person)
        #expect(ActionInvocation(arguments: ["url": .string("cmux://tab/x")], origin: .cli).linkOrigin == .person)
    }
}
