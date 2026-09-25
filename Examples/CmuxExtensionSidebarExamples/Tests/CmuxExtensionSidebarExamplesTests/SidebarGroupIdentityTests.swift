import CmuxSidebarProviderKit
@testable import CmuxExtensionSidebarExamples
import Foundation
import Testing

struct SidebarGroupIdentityTests {
    @Test(arguments: 0..<6)
    func everyBuiltInViewUsesGroupIdentityAndUpdatesLive(providerIndex: Int) throws {
        var snapshot = snapshot()
        let provider = providers(snapshot: snapshot)[providerIndex]
        for (symbol, color) in [("shippingbox.fill", "#123456"), ("star.fill", "#654321")] {
            snapshot.workspaces[0].workspaceGroupIconSymbol = symbol
            snapshot.workspaces[0].workspaceGroupColorHex = color
            let row = try #require(provider.render(snapshot: snapshot).sections.flatMap(\.rows).first)
            #expect(row.leadingIcon == CmuxSidebarProviderIcon(systemImageName: symbol, foregroundColorHex: color))
        }
        snapshot.workspaces[0].workspaceGroupIconSymbol = nil
        snapshot.workspaces[0].workspaceGroupColorHex = nil
        let row = try #require(provider.render(snapshot: snapshot).sections.flatMap(\.rows).first)
        if providerIndex == 5 {
            #expect(row.leadingIcon?.systemImageName == "bubble.left.fill")
            #expect(row.leadingIcon?.foregroundColorHex == "#D0D0D0")
        } else {
            #expect(row.leadingIcon == nil)
        }
    }

    @Test
    func colorOnlyUsesTintedFolder() throws {
        var snapshot = snapshot()
        snapshot.workspaces[0].workspaceGroupColorHex = "#123456"
        let row = try #require(AttentionQueueSidebar().render(snapshot: snapshot).sections.flatMap(\.rows).first)
        #expect(row.leadingIcon == CmuxSidebarProviderIcon(systemImageName: "folder.fill", foregroundColorHex: "#123456"))
    }

    @Test
    func attentionSectionRetainsMeaningAndDistinctGroupIdentities() throws {
        var snapshot = snapshot()
        snapshot.workspaces[0].unreadCount = 1
        snapshot.workspaces[0].workspaceGroupIconSymbol = "star.fill"
        snapshot.workspaces[0].workspaceGroupColorHex = "#123456"
        var second = snapshot.workspaces[0]
        second.id = UUID()
        second.workspaceGroupIconSymbol = "leaf.fill"
        second.workspaceGroupColorHex = "#654321"
        snapshot.workspaces.append(second)
        let section = try #require(AttentionQueueSidebar().render(snapshot: snapshot).sections.first)
        #expect(section.id == "attention")
        #expect(section.treeSection.systemImageName == "bell")
        #expect(section.rows.map { $0.leadingIcon?.systemImageName } == ["star.fill", "leaf.fill"])
        #expect(section.rows.map { $0.leadingIcon?.foregroundColorHex } == ["#123456", "#654321"])
    }

    @Test(arguments: ["Google", "Hacker News", "X", "Dia Browser"])
    func browserBrandIconsOverrideGroupIdentity(title: String) throws {
        var snapshot = snapshot()
        snapshot.workspaces[0].title = title
        let provider = providers(snapshot: snapshot)[5]
        let original = try #require(provider.render(snapshot: snapshot).sections.flatMap(\.rows).first?.leadingIcon)
        snapshot.workspaces[0].workspaceGroupIconSymbol = "star.fill"
        snapshot.workspaces[0].workspaceGroupColorHex = "#123456"
        let updated = try #require(provider.render(snapshot: snapshot).sections.flatMap(\.rows).first?.leadingIcon)
        #expect(updated == original)
    }

    private func providers(snapshot: CmuxSidebarProviderSnapshot) -> [any CmuxSidebarProvider] {
        [ProjectWorktreeSidebar(), AttentionQueueSidebar(), DevServerSidebar(),
         LastPromptSidebar(), SuperCompactSidebar(),
         BrowserStackSidebar(initialState: .initial(snapshot: snapshot))]
    }

    private func snapshot() -> CmuxSidebarProviderSnapshot {
        CmuxSidebarProviderSnapshot(sequence: 1, selectedWorkspaceId: nil, workspaces: [
            CmuxSidebarProviderWorkspace(
                id: UUID(), title: "Grouped workspace", customDescription: nil,
                isPinned: false, rootPath: "/tmp/grouped", projectRootPath: "/tmp/grouped",
                branchSummary: "main", remoteDisplayTarget: nil,
                remoteConnectionState: nil, unreadCount: 0, latestNotificationText: nil,
                latestSubmittedMessage: "hello", latestSubmittedAt: Date(timeIntervalSince1970: 1),
                listeningPorts: [3000]
            )
        ])
    }
}
