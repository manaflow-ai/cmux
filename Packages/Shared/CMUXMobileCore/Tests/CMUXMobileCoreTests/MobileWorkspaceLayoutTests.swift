import Foundation
import Testing
@testable import CMUXMobileCore

@Test func mobileWorkspacePaneLayoutRoundTripsWithNullSelection() throws {
    let layout = MobileWorkspaceLayoutNode.pane(
        paneID: "pane-a",
        tabs: [
            MobileWorkspaceLayoutTab(id: "terminal-a", kind: "terminal", title: "Agent"),
            MobileWorkspaceLayoutTab(id: "browser-a", kind: "browser", title: "Preview"),
        ],
        selectedTabID: nil
    )

    let data = try JSONEncoder().encode(layout)
    let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(object["type"] as? String == "pane")
    #expect(object["pane_id"] as? String == "pane-a")
    #expect(object.keys.contains("selected_tab_id"))
    #expect(object["selected_tab_id"] is NSNull)
    #expect(try JSONDecoder().decode(MobileWorkspaceLayoutNode.self, from: data) == layout)
}

@Test func mobileWorkspaceNestedSplitLayoutRoundTrips() throws {
    let layout = MobileWorkspaceLayoutNode.split(
        orientation: .horizontal,
        ratio: 0.6,
        first: .pane(
            paneID: "pane-left",
            tabs: [MobileWorkspaceLayoutTab(id: "terminal-agent", kind: "terminal", title: "Agent")],
            selectedTabID: "terminal-agent"
        ),
        second: .split(
            orientation: .vertical,
            ratio: 0.4,
            first: .pane(
                paneID: "pane-top-right",
                tabs: [MobileWorkspaceLayoutTab(id: "browser-preview", kind: "browser", title: "Preview")],
                selectedTabID: "browser-preview"
            ),
            second: .pane(
                paneID: "pane-bottom-right",
                tabs: [MobileWorkspaceLayoutTab(id: "other-notes", kind: "other", title: "Notes")],
                selectedTabID: "other-notes"
            )
        )
    )

    let data = try JSONEncoder().encode(layout)
    let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    let second = try #require(object["second"] as? [String: Any])
    #expect(object["type"] as? String == "split")
    #expect(object["orientation"] as? String == "horizontal")
    #expect(object["ratio"] as? Double == 0.6)
    #expect(second["type"] as? String == "split")
    #expect(second["orientation"] as? String == "vertical")
    #expect(try JSONDecoder().decode(MobileWorkspaceLayoutNode.self, from: data) == layout)
}
