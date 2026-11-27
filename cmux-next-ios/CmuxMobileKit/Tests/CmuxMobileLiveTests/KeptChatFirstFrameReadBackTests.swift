#if os(iOS)
import CmuxMobileAgentChat
import Foundation
import SwiftUI
import Testing
import UIKit
@testable import CmuxMobileLive

/// Read-back for the kept chat's first frame (Leo, 2026-11-14: "load faster/percievably load
/// faster"). A relaunch (a fresh cache, only the disk holds the chat, no link) opens the real chat
/// screen (`AgentChatScreen` in a navigation stack, in a window) on the
/// chat's source. It saves what the screen drew at its first frame and half a second later as
/// test attachments, with one `KEPTFRAME` log line per state. Before, the first frame was the
/// spinner ("Connecting to mini…"). The test host has no window scene, so the snapshots draw the
/// screen's chrome and the spinner but not the transcript's rows: the turns are checked on the
/// store. Run it on its own: a suite running beside it on the main actor (the timing harness's
/// yield loop) delays its frames.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(2))) struct KeptChatFirstFrameReadBackTests {
    typealias Kept = AgentKeptTranscriptTests
    typealias Long = LongChatOpenLiveTests

    @Test func readBackARelaunchedChatsFirstFrame() async throws {
        let directory = Kept.folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let key = try #require(AgentTranscriptCache.key(accountID: "acct", macID: "mac1", tabID: "s7"))
        let writer = Kept.cache(directory)
        writer.save(key, sessionID: "s1", earlier: false, records: Kept.json((0..<20).flatMap(Long.turnRecords)))
        writer.flush()

        var log: [String] = []
        let start = ContinuousClock.now
        func line(_ name: String, _ store: AgentChatStore, _ extra: String = "") {
            let ms = Double((ContinuousClock.now - start) / .microseconds(1)) / 1000
            let spinner = store.isLoadingHistory && !store.hasTurns || store.awaitsFirstPrompt
            log.append("KEPTFRAME \(name) t=\(ms)ms turns=\(store.turns.count) spinner=\(spinner) newest=\(store.turns.last?.id ?? "-")\(extra)")
        }

        // The relaunch: a new cache instance (nothing in memory) and a hub with no link.
        let hub = Kept.hub(Kept.cache(directory))
        let source = hub.source(sessionID: "s1", summary: Kept.summary)
        let store = AgentChatStore(source: source)
        line("0-open", store, " replay=\(source.replayCount)")
        let host = UIHostingController(rootView: NavigationStack { AgentChatScreen(store: store) })
        let scene = UIApplication.shared.connectedScenes.lazy.compactMap { $0 as? UIWindowScene }.first
        let window = scene.map { UIWindow(windowScene: $0) } ?? UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        window.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        window.overrideUserInterfaceStyle = .dark
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true }

        func shot(_ name: String) -> (spinner: Bool, turns: Int) {
            window.layoutIfNeeded()
            CATransaction.flush()
            line(name, store, " scene=\(scene != nil)")
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { context in
                if !window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) {
                    window.layer.render(in: context.cgContext)
                }
            }
            if let png = image.pngData() { Attachment.record(png, named: "kept-chat-\(name).png") }
            return (store.isLoadingHistory && !store.hasTurns || store.awaitsFirstPrompt, store.turns.count)
        }

        // The first frame: what the screen holds when the run loop first draws it. The store's
        // reader task was queued at its init, ahead of this hop; give the main actor its turns
        // (no timer: the count is bounded, not waited on) so it applies the kept batch first.
        for _ in 0..<20 where !store.hasTurns { await Task.yield() }
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
        let first = shot("1-first-frame")
        try? await Task.sleep(for: .milliseconds(500)) // test: the settled screen, for comparison
        let settled = shot("2-settled-500ms")
        let text = log.joined(separator: "\n")
        print(text)
        Attachment.record(text, named: "keptframe-log.txt")

        #expect(source.replayCount > 0, "the kept turns are restored in the open's own turn")
        #expect(!first.spinner, "the first frame draws the kept turns, not \"Loading chat…\"")
        #expect(first.turns == 20, "all 20 kept turns are in the first frame")
        #expect(settled.turns == 20)
        #expect(store.turns.last?.id == "t19")
        withExtendedLifetime(hub) {}
    }
}
#endif
