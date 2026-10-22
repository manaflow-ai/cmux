import Testing
@testable import CmuxNextAgentPane

/// Debug Settings' Needs you list: on by default, so the default sets no attribute; the other
/// choices set `data-needs-you` for the page (needsYou/NeedsYou.tsx). The list shows only while its
/// App Store item is installed (``AgentPaneTunables/needsYouStyle(installed:debug:)``). The Needs
/// your input pill and its toggle are gone (Leo 2026-10-21).
struct AgentPaneNeedsYouTunablesTests {
    @Test func defaultsAreOnAndSetNoAttribute() {
        #expect(AgentPaneTunables.needsYou.descriptor.key == "agentPane.debug.needsYou")
        #expect(AgentPaneTunables.needsYou.defaultValue == .pinned)
        #expect(AgentPaneTunables.attributes(foldLongThoughts: true, topStripStyle: .default).isEmpty)
    }

    @Test(arguments: [AgentPaneNeedsYouStyle.compact, .off])
    func otherStylesSetTheirAttribute(style: AgentPaneNeedsYouStyle) {
        #expect(AgentPaneTunables.attributes(foldLongThoughts: true, topStripStyle: .default, needsYou: style)
            == ["needs-you": style.rawValue])
    }

    /// Needs you is an App Store item (`agentPane.needsYou.enabled`, off by default; Leo
    /// 2026-10-22): not installed, a new page gets `needs-you="off"` whatever Debug Settings says;
    /// installed, the Debug choice applies as before.
    @Test(arguments: AgentPaneNeedsYouStyle.allCases)
    func notInstalledIsOffWhateverTheDebugChoice(debug: AgentPaneNeedsYouStyle) {
        let style = AgentPaneTunables.needsYouStyle(installed: false, debug: debug)
        #expect(style == .off)
        #expect(AgentPaneTunables.attributes(foldLongThoughts: true, topStripStyle: .default, needsYou: style)
            == ["needs-you": "off"])
        #expect(AgentPaneTunables.needsYouStyle(installed: true, debug: debug) == debug)
    }

    @Test func listedInDebugSettings() {
        #expect(AgentPaneTunables.all.contains { $0.key == "agentPane.debug.needsYou" })
        #expect(!AgentPaneTunables.all.contains { $0.key == "agentPane.debug.needsYouPill" })
        #expect(AgentPaneNeedsYouStyle.allCases.map(\.rawValue) == ["pinned", "compact", "off"])
    }
}
