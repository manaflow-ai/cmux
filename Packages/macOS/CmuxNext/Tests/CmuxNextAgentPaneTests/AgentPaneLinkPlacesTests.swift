@testable import CmuxNextAgentPane
import CmuxNextSettings
import Testing

/// The places a pasted cmux link names (`linkPlaces`): the page gets `{id, kind, title, host?,
/// workspace?}` entries (webviews chips/cmuxLinkPlaces.ts), only the members that are set.
@MainActor
struct AgentPaneLinkPlacesTests {
    @Test func thePageGetsEachPlaceByItsIdKindAndTitle() {
        let event = AgentPageEvent.linkPlaces([
            .init(id: "ws_16c92e4354fcaf05540386720d78e251", kind: .workspace, title: "Research"),
            .init(id: "tab_0123456789abcdef0123456789abcdef", kind: .tab, title: "zsh", host: "build-box", workspace: "Research"),
        ])
        #expect(event.kind == "linkPlaces")
        #expect(event.value == .array([
            ["id": "ws_16c92e4354fcaf05540386720d78e251", "kind": "workspace", "title": "Research"],
            ["id": "tab_0123456789abcdef0123456789abcdef", "kind": "tab", "title": "zsh", "host": "build-box", "workspace": "Research"],
        ]))
        #expect(AgentPageEvent.linkPlaces([]).value == .array([]))
    }
}
