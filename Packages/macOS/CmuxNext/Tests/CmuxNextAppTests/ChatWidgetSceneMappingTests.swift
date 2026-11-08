import CmuxHomeRender
import CmuxNextApps
import Testing
@testable import CmuxNextApp

/// A chat widget's scene as the snapshot Home draws (plans/cmux-next/chat-widgets-DESIGN.md
/// section 4): the PR card's tree from samples/apps/pr-card.
@Suite struct ChatWidgetSceneMappingTests {
    @Test func thePRCardSceneMapsToTextRowsABadgeAndARowOfButtons() throws {
        var scene = AppScene()
        scene.apply([
            .create(id: "n1", type: "VStack", props: [:]),
            .create(id: "n2", type: "Text", props: ["text": "Widgets in chat", "font": "headline"]),
            .create(id: "n3", type: "Row", props: ["title": "o/r #7", "subtitle": "Open · octo", "symbol": "arrow.triangle.pull",
                                                    "tint": "success", "onTap": true]),
            .create(id: "n4", type: "Badge", props: ["text": "1 failed · 6 passed", "tone": "danger"]),
            .create(id: "n5", type: "Divider", props: [:]),
            .create(id: "n6", type: "ForEach", props: [:]),
            .create(id: "n7", type: "Row", props: ["title": "check-7", "subtitle": "Failed", "symbol": "xmark.circle", "tint": "danger"]),
            .create(id: "n8", type: "HStack", props: [:]),
            .create(id: "n9", type: "Button", props: ["title": "Previous", "disabled": true, "onTap": true]),
            .create(id: "n10", type: "Button", props: ["title": "Next", "background": "accent", "onTap": true]),
            .create(id: "n11", type: "Image", props: ["src": "assets/logo.png"]),
            .children(id: "n6", children: ["n7"]),
            .children(id: "n8", children: ["n9", "n10"]),
            .children(id: "n1", children: ["n2", "n3", "n4", "n5", "n6", "n8", "n11"]),
            .root(id: "n1"),
        ])
        let snapshot = try #require(ChatWidgetSceneMapping().snapshot(scene))
        #expect(snapshot.items == [
            .text("Widgets in chat", style: .headline, tint: .primary),
            .row(node: "n3", title: "o/r #7", subtitle: "Open · octo", symbol: "arrow.triangle.pull", tint: .success, badge: nil),
            .badge("1 failed · 6 passed", tint: .danger),
            .divider,
            // No onTap: drawn, not clickable.
            .row(node: nil, title: "check-7", subtitle: "Failed", symbol: "xmark.circle", tint: .danger, badge: nil),
            .buttons([HomeWidgetButton(node: "n9", title: "Previous", prominent: false, enabled: false),
                      HomeWidgetButton(node: "n10", title: "Next", prominent: true, enabled: true)]),
        ])
    }

    @Test func aSceneWithNoRootIsNoSnapshot() {
        #expect(ChatWidgetSceneMapping().snapshot(AppScene()) == nil)
    }
}
