import CmuxNextSettings
import Foundation
import Testing
@testable import CmuxNextAgentPane
import CmuxNextPagesTestSupport

/// a251 (Oct 20): when the Recently Closed list changed, every open New Tab page built and
/// serialized the same list (favicons as data URLs included) again: work linear in the number of
/// open pages on the main thread. The list is now encoded once and the same payload reaches
/// every page.
@Suite(.serialized)
@MainActor
struct RecentlyClosedSharedEncodeTests {
    private actor NoHost: AgentPaneHostProviding {
        func handshake(sessionId: String?) async throws -> AgentPaneHandshake { throw AgentPaneHostError.daemonStopped }
    }

    private final class Counter {
        var encodes = 0
    }

    private static let items = (0..<AgentPaneClosedItem.maximumPushed).map { index in
        AgentPaneClosedItem(id: "closed:\(index)", kind: .browser, title: "Page \(index)", detail: "https://example.com/\(index)",
                            closedAt: Date(timeIntervalSince1970: 1_790_000_000 + Double(index)),
                            icon: "data:image/png;base64," + String(repeating: "A", count: 4096), isAvailable: true)
    }

    private static func page() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appending(path: "closed-encode-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appending(path: "index.html")
        try Data("<html><body></body></html>".utf8).write(to: file)
        return file
    }

    @Test(arguments: [1, 8, 24])
    func oneChangeEncodesTheListOnceForAnyNumberOfPages(pages: Int) throws {
        let file = try Self.page()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let views = try (0..<pages).map { _ in try #require(AgentPaneView(model: AgentPaneModel(host: NoHost()), source: .bundled(file), errors: DroppedErrors())) }

        let counter = Counter()
        let list = AgentPaneClosedList(Self.items) { item in
            counter.encodes += 1
            return item.json
        }
        for view in views { view.recentlyClosed = list }

        #expect(counter.encodes == Self.items.count,
                "\(pages) open New Tab pages encoded the closed list \(counter.encodes / Self.items.count) times, not once")
        for view in views {
            #expect(view.recentlyClosed.items == Self.items)
            #expect(AgentPanePageHost.currentEvents(view).contains(list.event))
        }
        #expect(counter.encodes == Self.items.count, "a page's handshake replay encoded the closed list again")
    }

    @Test func thePayloadMatchesThePerItemEncoding() {
        let list = AgentPaneClosedList(Self.items)
        #expect(list.event == AgentPageEvent(kind: "recentlyClosed", value: .array(Self.items.map(\.json))))
        #expect(list.script == "window.cmuxAcpmuxBridge?.applyRecentlyClosed?.(\(list.event.value.compactText));")
        #expect(AgentPaneClosedList(Self.items + Self.items).items.count == AgentPaneClosedItem.maximumPushed)
    }
}
