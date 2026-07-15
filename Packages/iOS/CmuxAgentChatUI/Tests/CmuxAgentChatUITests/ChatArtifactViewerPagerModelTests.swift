import CmuxAgentChat
import Foundation
import Testing

@testable import CmuxAgentChatUI

@Suite("Artifact viewer pager ownership")
struct ChatArtifactViewerPagerModelTests {
    @Test("keeps page identity stable across gallery snapshot updates")
    @MainActor
    func keepsStablePageIdentity() throws {
        let defaults = try #require(UserDefaults(suiteName: "cmux.viewer-pager.\(UUID().uuidString)"))
        let initialOrder = swipeOrder([
            item(path: "/logs/build.log", size: 11_000_000),
            item(path: "/logs/test.log", size: 2_000),
        ])
        let model = ChatArtifactViewerPagerModel(
            initialPath: "/logs/build.log",
            swipeOrder: initialOrder,
            textPreferences: ChatArtifactTextPreferences(defaults: defaults)
        )
        let initialIdentity = try #require(model.pageIdentity(for: "/logs/build.log"))

        model.update(swipeOrder: swipeOrder([
            item(path: "/logs/new.log", size: 40),
            item(path: "/logs/build.log", size: 11_500_000),
            item(path: "/logs/test.log", size: 2_000),
        ]))

        #expect(model.pageIdentity(for: "/logs/build.log") == initialIdentity)
        #expect(model.pageSnapshots.map(\.path) == ["/logs/new.log", "/logs/build.log"])
    }

    @Test("projects toolbar state from exactly the selected page")
    @MainActor
    func projectsOneToolbarState() throws {
        let defaults = try #require(UserDefaults(suiteName: "cmux.viewer-toolbar.\(UUID().uuidString)"))
        let model = ChatArtifactViewerPagerModel(
            initialPath: "/first.txt",
            swipeOrder: swipeOrder([
                item(path: "/first.txt", size: 10),
                item(path: "/second.txt", size: 20),
                item(path: "/third.txt", size: 30),
            ]),
            textPreferences: ChatArtifactTextPreferences(defaults: defaults)
        )

        #expect(model.toolbarSnapshot.path == "/first.txt")
        model.select(path: "/second.txt")
        #expect(model.toolbarSnapshot.path == "/second.txt")
        #expect(model.pageSnapshots.count == 3)
    }

    @Test("snapshot refreshes do not replay jump requests")
    @MainActor
    func keepsJumpRequestIdentity() throws {
        let defaults = try #require(UserDefaults(suiteName: "cmux.viewer-jumps.\(UUID().uuidString)"))
        let model = ChatArtifactViewerPagerModel(
            initialPath: "/build.log",
            swipeOrder: swipeOrder([item(path: "/build.log", size: 11_000_000)]),
            textPreferences: ChatArtifactTextPreferences(defaults: defaults)
        )

        model.requestTop()
        let requestID = model.toolbarSnapshot.topRequestID
        model.update(swipeOrder: swipeOrder([
            item(path: "/build.log", size: 11_500_000),
            item(path: "/new.log", size: 100),
        ]))

        #expect(requestID == 1)
        #expect(model.toolbarSnapshot.topRequestID == requestID)
    }

    private func swipeOrder(_ items: [ChatArtifactGalleryItem]) -> ChatArtifactGallerySwipeOrder {
        ChatArtifactGallerySwipeOrder(items: items)
    }

    private func item(path: String, size: Int64) -> ChatArtifactGalleryItem {
        ChatArtifactGalleryItem(
            path: path,
            kind: .text,
            displayName: URL(fileURLWithPath: path).lastPathComponent,
            size: size,
            modifiedAt: Date(timeIntervalSince1970: Double(size))
        )
    }
}
