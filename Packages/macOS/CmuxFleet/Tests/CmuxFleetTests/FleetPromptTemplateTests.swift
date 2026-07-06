import CmuxFleet
import Foundation
import Testing

struct FleetPromptTemplateTests {
    @Test
    func renderShellQuotesEveryStringPlaceholder() {
        let rendered = FleetPromptTemplate().render(
            template: "cd {{DIR}} && git checkout {{BRANCH}} && claude {{PROMPT}} # {{TASK_ID}}",
            task: Self.task(title: "Fix Bob's bug", body: "Don't fail"),
            directory: "/Users/Jane Smith/code-fleet/task",
            branch: "fleet/task"
        )
        #expect(rendered == "cd '/Users/Jane Smith/code-fleet/task' && git checkout 'fleet/task' "
            + "&& claude 'Fix Bob'\\''s bug\n\nDon'\\''t fail' # local:1")
    }

    @Test
    func renderUsesTitleForEmptyBodyAndDropsMissingBranch() {
        let rendered = FleetPromptTemplate().render(
            template: "claude {{PROMPT}} --title {{TITLE}} --body {{BODY}} --branch {{BRANCH}}",
            task: Self.task(title: "Title only", body: ""),
            directory: "/tmp/fleet",
            branch: nil
        )
        #expect(rendered == "claude 'Title only' --title 'Title only' --body '' --branch ")
    }

    private static func task(title: String, body: String) -> FleetTask {
        FleetTask(
            id: FleetTaskID(rawValue: "local:1"),
            sourceKind: .local,
            key: "local:1",
            title: title,
            body: body,
            sourceState: "open",
            createdAt: Date(timeIntervalSince1970: 10_000),
            updatedAt: Date(timeIntervalSince1970: 10_000)
        )
    }
}
