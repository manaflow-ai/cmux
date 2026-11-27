#if os(iOS)
import CmuxMobileAgentChat
import CmuxMobileFeed
import CmuxMobileModel
import CmuxMobileTransport
import Foundation
import SwiftUI
import Testing
import UIKit
@testable import CmuxMobileLive

/// A dial that never answers: the relaunched phone has no link to the Mac yet.
private struct NeverAnsweringDialer: MacLinkDialer {
    func dial(_ endpoint: LinkEndpoint, transport: CmuxMobileTransport.TransportKind, accessToken: String) async throws -> any MacLink {
        try await Task.sleep(for: .seconds(3600)) // test: the link never comes up; stop() cancels it
        throw LinkError(code: "test", message: "never answers")
    }
}

/// The coordinator's relaunch path, end to end (Leo, 2026-11-14: "load faster/percievably load
/// faster"). A chat is kept with its head file on disk. The relaunch is a fresh `LiveCoordinator`
/// with a fresh cache (nothing in memory) and no link to the Mac. The relaunched tab's
/// `makeSource` (the one the chat screen's store is built from) opens the chat on its kept
/// session's acpmux source directly, not a `PendingAgentSource`. That source restores the head's
/// turns in its init, the real chat screen shows them with no link, and when the Mac's chats
/// come the attach reads after the head's newest seq.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(2))) struct KeptChatCoordinatorRelaunchTests {
    typealias Kept = AgentKeptTranscriptTests
    typealias Long = LongChatOpenLiveTests

    let host = "svc-\(UUID().uuidString.prefix(8).lowercased()).cmuxMobile.test"
    let userID = "user-\(UUID().uuidString)"

    func relaunchedCoordinator(_ store: AppStore) -> LiveCoordinator {
        let directory = FileManager.default.temporaryDirectory.appending(path: "cmux-mobile-kept-relaunch-\(UUID().uuidString)")
        let snapshots = LiveSnapshotStore(directory: directory)
        snapshots.save(LiveSnapshot(
            teamID: "t-kept-relaunch", teamName: "One",
            macs: [MacDevice(id: "m1", name: "mini", isOnline: true)],
            linkedMacID: "m1",
            workspaces: ["m1": .init(workspaces: [], savedAt: Date(timeIntervalSince1970: 1_000))]
        ), accountID: userID)
        snapshots.flush()
        return LiveCoordinator(
            store: store,
            api: LiveAPI(baseURL: URL(string: "https://\(host)")!, session: ServiceStub.session()) { _ in "token" },
            identity: DeviceIdentity(link: UUID().uuidString, presence: UUID().uuidString),
            userID: userID, deviceName: "iPhone", transport: .wireGuard, dialer: NeverAnsweringDialer(),
            feedStore: FeedStore(items: []), snapshots: snapshots
        )
    }

    @Test func aRelaunchedTabOpensOnItsKeptSessionAndReadsAfterTheHead() async throws {
        let macKey = "cmuxMobile.live.mac.t-kept-relaunch"
        UserDefaults.standard.removeObject(forKey: macKey)
        defer { UserDefaults.standard.removeObject(forKey: macKey) }
        let directory = Kept.folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let key = try #require(AgentTranscriptCache.key(accountID: userID, macID: "m1", tabID: "s7"))
        let writer = Kept.cache(directory)
        writer.save(key, sessionID: "s1", earlier: false, records: Kept.json((0..<Kept.keptTurns).flatMap(Long.turnRecords)))
        writer.flush()
        #expect(FileManager.default.fileExists(atPath: writer.headFile(for: key).path(percentEncoded: false)))

        // The relaunch: a fresh coordinator and a fresh cache over the kept folder, no link.
        let store = AppStore(teams: [], activeTeamID: "", workspaces: [], feed: [], tabMemory: .inMemory())
        let live = relaunchedCoordinator(store)
        defer { live.stop() }
        // Taken in the same turn as the init: other suites' coordinators set the shared directory too.
        let makeSource = AgentSessionDirectory.shared.makeSource
        let cache = Kept.cache(directory)
        live.transcriptCache = cache
        let owner = try #require(live.sessions["m1"], "the snapshot's Mac has its session at launch")
        owner.acpmux.transcriptCache = cache
        #expect(owner.tree == nil, "the Mac's tree has not come")
        #expect(cache.cached(key) == nil, "nothing in memory")

        let summary = AgentSessionSummary(id: "s7", name: "Fix", harness: "codex", agentName: "Codex", cwd: "/tmp/w",
                                          workspaceTitle: "w", macName: "mini", macID: "m1")
        let made = makeSource(summary)
        let source = try #require(made as? AcpmuxSessionSource, "the kept session's source, not \(type(of: made))")
        #expect(source.replayCount > 0, "the head's turns, restored in the source's init")
        let sourced = live.sourcedSessions[AgentSessionDirectory.key(id: "s7", macID: "m1")]
        #expect(sourced?.session == "s1")
        #expect(sourced?.provisional == true)

        // The real chat screen on that source, as the relaunched tab shows it.
        let chat = AgentChatStore(source: source)
        let start = ContinuousClock.now
        var log: [String] = []
        func line(_ name: String, _ extra: String = "") {
            let ms = Double((ContinuousClock.now - start) / .microseconds(1)) / 1000
            let spinner = chat.isLoadingHistory && !chat.hasTurns || chat.awaitsFirstPrompt
            log.append("RELAUNCHFRAME \(name) t=\(ms)ms turns=\(chat.turns.count) spinner=\(spinner) newest=\(chat.turns.last?.id ?? "-")\(extra)")
        }
        line("0-open", " replay=\(source.replayCount)")
        let hostView = UIHostingController(rootView: NavigationStack { AgentChatScreen(store: chat) })
        let scene = UIApplication.shared.connectedScenes.lazy.compactMap { $0 as? UIWindowScene }.first
        let window = scene.map { UIWindow(windowScene: $0) } ?? UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        window.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        window.overrideUserInterfaceStyle = .dark
        window.rootViewController = hostView
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        func shot(_ name: String) -> Bool {
            window.layoutIfNeeded()
            CATransaction.flush()
            line(name)
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { context in
                if !window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) {
                    window.layer.render(in: context.cgContext)
                }
            }
            if let png = image.pngData() { Attachment.record(png, named: "relaunch-chat-\(name).png") }
            return chat.isLoadingHistory && !chat.hasTurns || chat.awaitsFirstPrompt
        }
        // The store applies the source's restored batch on its own task; a suite running beside this
        // one on the main actor can delay that task past the first frame, so the first frame itself
        // is `KeptChatFirstFrameReadBackTests`'s (run on its own). Here: still no link, the screen
        // shows the head's turns, not "Loading chat…".
        await Long.waitUntil { chat.hasTurns }
        let keptSpinner = shot("1-kept-turns-no-link")
        #expect(!keptSpinner, "the kept turns, not \"Loading chat…\"")
        #expect(chat.isLoadingHistory, "still no link: the chat has not caught up")
        #expect(chat.turns.last?.id == "t119")
        let headTurns = chat.turns.count
        #expect(headTurns > 0 && headTurns < Kept.keptTurns, "the head's newest turns, not the whole copy")

        // The Mac's chats come (the link the coordinator would bind): the attach reads after 600.
        let requests = Long.Requests()
        await owner.acpmux.bind(try await Long.fakeAcpmux(Kept.macLog, requests).openChannel(service: "acpmux", args: [:]))
        await Long.waitUntil { chat.turns.last?.id == "t122" && !chat.isLoadingHistory }
        _ = shot("2-caught-up")
        let attaches = requests.all.filter { $0.method == "_acpmux/attach" }
        #expect(attaches.count == 1)
        #expect((attaches.first?.params["afterSeq"] as? NSNumber)?.intValue == 600, "the attach reads after the head's newest seq")
        #expect(attaches.first?.params["maxBytes"] == nil, "a forward read from the kept copy, not a first open")
        Kept.expectInOrderThroughNewest(chat)
        #expect(chat.turns.count == headTurns + 3)

        let text = log.joined(separator: "\n")
        print(text)
        Attachment.record(text, named: "relaunchframe-log.txt")
        withExtendedLifetime(source) {}
    }
}
#endif
