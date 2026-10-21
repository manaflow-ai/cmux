import Testing
@testable import CmuxNextAgentPane

/// Debug Settings' Needs you list and pill: both on by default, so the defaults set no attribute;
/// the other choices set `data-needs-you` / `data-needs-you-pill` for the page (needsYou/NeedsYou.tsx).
struct AgentPaneNeedsYouTunablesTests {
    @Test func defaultsAreOnAndSetNoAttribute() {
        #expect(AgentPaneTunables.needsYou.descriptor.key == "agentPane.debug.needsYou")
        #expect(AgentPaneTunables.needsYou.defaultValue == .pinned)
        #expect(AgentPaneTunables.needsYouPill.descriptor.key == "agentPane.debug.needsYouPill")
        #expect(AgentPaneTunables.needsYouPill.defaultValue == true)
        #expect(AgentPaneTunables.attributes(foldLongThoughts: true, topStripStyle: .default).isEmpty)
    }

    @Test(arguments: [AgentPaneNeedsYouStyle.compact, .off])
    func otherStylesSetTheirAttribute(style: AgentPaneNeedsYouStyle) {
        #expect(AgentPaneTunables.attributes(foldLongThoughts: true, topStripStyle: .default, needsYou: style)
            == ["needs-you": style.rawValue])
    }

    @Test func pillOffSetsItsAttribute() {
        #expect(AgentPaneTunables.attributes(foldLongThoughts: true, topStripStyle: .default, needsYouPill: false)
            == ["needs-you-pill": "off"])
    }

    @Test func listedInDebugSettings() {
        #expect(AgentPaneTunables.all.contains { $0.key == "agentPane.debug.needsYou" })
        #expect(AgentPaneTunables.all.contains { $0.key == "agentPane.debug.needsYouPill" })
        #expect(AgentPaneNeedsYouStyle.allCases.map(\.rawValue) == ["pinned", "compact", "off"])
    }
}
