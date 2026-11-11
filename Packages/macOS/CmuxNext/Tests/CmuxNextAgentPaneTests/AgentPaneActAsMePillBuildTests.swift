import AppKit
import Foundation
import Testing
@testable import CmuxNextAgentPane

/// CMD-T BUDGET 3, cause (c) (2026-11-10): one refill of the New Tab spare pool held the main thread for about
/// 14 ms, and about 5 ms of that built the "Computer use can act as me" pill (a glass surface, a stack and a
/// button) for a grant that is off by default: every page built one and kept it hidden.
///
/// The count: the pills in `count` pages made while the grant is off. The number of pages is the one argument; the
/// answer must be 0 for every size. The pill still shows in each page once the grant is on, hides when it is off
/// again, and a page made while the grant is on has its pill at once.
@Suite(.serialized)
@MainActor
struct AgentPaneActAsMePillBuildTests {
    private actor NoHost: AgentPaneHostProviding {
        func handshake(sessionId: String?) async throws -> AgentPaneHandshake { throw AgentPaneHostError.daemonStopped }
    }

    private static func pills(in page: AgentPaneView) -> [AgentPaneActAsMeBadge] {
        page.subviews.compactMap { $0 as? AgentPaneActAsMeBadge }
    }

    /// `count` pages over the app's one grant, as the agent tabs make them (``AgentPaneShared``).
    private static func pages(_ count: Int, grant: AgentPaneActAsMe, page file: URL) throws -> [AgentPaneView] {
        let shared = AgentPaneShared(actAsMe: grant, microphone: nil)
        return try (0..<count).map { _ in
            try #require(AgentPaneView(model: AgentPaneModel(host: NoHost()), source: .bundled(file), shared: shared), "fixture: no page")
        }
    }

    /// Gives the main actor to the grant's followers until `done`, for at most 2 s.
    private static func until(_ done: () -> Bool) async throws {
        for _ in 0..<400 where !done() { try await Task.sleep(for: .milliseconds(5)) }
    }

    @Test(.timeLimit(.minutes(1)), arguments: [1, 3, 12])
    func aPageBuildsNoPillWhileTheGrantIsOff(count: Int) async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appending(path: "act-as-me-pill-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appending(path: "index.html")
        try Data("<html></html>".utf8).write(to: file)
        let grant = AgentPaneActAsMe()
        let pages = try Self.pages(count, grant: grant, page: file)
        var late: [AgentPaneView] = []
        defer {
            (pages + late).forEach { $0.close() }
            try? FileManager.default.removeItem(at: directory)
        }

        let builtWhileOff = pages.map { Self.pills(in: $0).count }.reduce(0, +)
        #expect(builtWhileOff == 0, "\(builtWhileOff) of \(count) pages built the pill while the grant was off")

        // Each page's follower starts and waits on a grant that is off: still no pill. The turn-on below then
        // wakes a follower that waits, which is the path of a person's click.
        try await Task.sleep(for: .milliseconds(50))
        let builtWhileWaiting = pages.map { Self.pills(in: $0).count }.reduce(0, +)
        #expect(builtWhileWaiting == 0, "\(builtWhileWaiting) of \(count) pages built the pill later, while the grant was still off")

        // The grant turns on (an administrator's profile): each page shows one pill.
        grant.setManaged(true)
        try await Self.until { pages.allSatisfy { Self.pills(in: $0).first?.isHidden == false } }
        #expect(pages.map { Self.pills(in: $0).count } == Array(repeating: 1, count: count))
        #expect(pages.allSatisfy { Self.pills(in: $0).first?.isHidden == false }, "a page shows no pill while the grant is on")
        #expect(pages.allSatisfy { $0.actAsMePill.badge === Self.pills(in: $0).first })

        // Turn Off: the pill hides in each page.
        grant.turnOff()
        try await Self.until { pages.allSatisfy { Self.pills(in: $0).first?.isHidden == true } }
        #expect(pages.allSatisfy { Self.pills(in: $0).first?.isHidden == true }, "a page shows the pill while the grant is off")

        // On again (the person's click on the card): the same pill shows, never a second one.
        grant.turnOn(.init())
        try await Self.until { pages.allSatisfy { Self.pills(in: $0).first?.isHidden == false } }
        #expect(pages.map { Self.pills(in: $0).count } == Array(repeating: 1, count: count))
        #expect(pages.allSatisfy { Self.pills(in: $0).first?.isHidden == false })

        // A page made while the grant is on has its pill in the turn that made it.
        late = try Self.pages(1, grant: grant, page: file)
        #expect(Self.pills(in: late[0]).count == 1)
        #expect(Self.pills(in: late[0]).first?.isHidden == false)
    }
}
