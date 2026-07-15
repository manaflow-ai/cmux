import CmuxMobileShellModel
import Testing
@testable import CmuxMobileShellUI

@MainActor
@Suite struct WorkspaceSurfaceGridCardTests {
    @Test func equalityUsesOnlyImmutableItemSnapshot() {
        let item = makeItem(title: "Browser", detail: "https://example.com", isSelected: false)
        let first = WorkspaceSurfaceGridCard(item: item, open: {}, close: {})
        let second = WorkspaceSurfaceGridCard(item: item, open: { _ = 1 }, close: { _ = 2 })

        #expect(first == second)
        #expect(first != WorkspaceSurfaceGridCard(
            item: makeItem(title: "Docs", detail: "https://example.com", isSelected: false),
            open: {},
            close: {}
        ))
        #expect(first != WorkspaceSurfaceGridCard(
            item: makeItem(title: "Browser", detail: "https://example.com/docs", isSelected: true),
            open: {},
            close: {}
        ))
    }

    private func makeItem(title: String, detail: String, isSelected: Bool) -> WorkspaceSurfaceGridItem {
        WorkspaceSurfaceGridItem(
            id: "browser-surface-1",
            workspaceID: .init(rawValue: "workspace-1"),
            kind: .browser,
            title: title,
            subtitle: "Browser",
            detail: detail,
            systemImage: "globe",
            isSelected: isSelected,
            isDimmed: false,
            canClose: true
        )
    }
}
