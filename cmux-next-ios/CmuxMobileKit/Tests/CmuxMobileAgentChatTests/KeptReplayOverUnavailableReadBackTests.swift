#if os(iOS)
import CmuxMobileModel
import Foundation
import SwiftUI
import Testing
import UIKit
@testable import CmuxMobileAgentChat

/// Read-back for the replay screen when the phone holds a kept recording and the Mac answers
/// that it cannot read the replay (`AgentFeatureUnavailable`). Before, "Couldn't load this
/// chat's history." covered the recording already playing; now the recording stays. The real
/// `ReplayConversationScreen` is drawn in a window on the simulator and saved as a test
/// attachment, and as a PNG in `CMUX_VISUAL_OUT` when set (`TEST_RUNNER_CMUX_VISUAL_OUT` for
/// xcodebuild), so a run at the base and one at the head give the before and after.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(1))) struct KeptReplayOverUnavailableReadBackTests {
    @Test func readBackAKeptReplayOverAMacThatCannotReadIt() async throws {
        ChatReplayPlayer.forgetKept()
        defer { ChatReplayPlayer.forgetKept() }
        let summary = ChatDrawsKeptNotLoadingTests.summary("replay-readback-\(UUID().uuidString)")
        ChatReplayPlayer.keep(ChatDrawsKeptNotLoadingTests.recording(prompts: 3),
                              for: AgentSessionDirectory.key(id: summary.id, macID: summary.macID))
        // A replay source reads no recording: the protocol's default throws AgentFeatureUnavailable.
        let store = AgentChatStore(source: ReplaySource(summary: summary))
        // Loaded here, not by the screen's .task: a test host has no scene on screen to run it.
        let player = ChatReplayPlayer()
        await player.load(store)
        player.pause()
        if player.state == .ready { player.seek(to: player.duration) } // every kept prompt on screen
        let host = UIHostingController(rootView: NavigationStack { ReplayConversationScreen(store: store, player: player) })
        host.view.backgroundColor = .black
        let scene = UIApplication.shared.connectedScenes.lazy.compactMap { $0 as? UIWindowScene }.first
        let window = scene.map { UIWindow(windowScene: $0) } ?? UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        window.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        window.overrideUserInterfaceStyle = .dark
        window.backgroundColor = .black
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true }

        // The screen's load runs from its .task; the source answers at once, so a bounded number of
        // main-actor turns and one settled half second hold the answer.
        for _ in 0 ..< 50 { await Task.yield() }
        try? await Task.sleep(for: .milliseconds(500)) // test: the settled screen
        window.layoutIfNeeded()
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        CATransaction.flush()
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { context in
            if !window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) {
                window.layer.render(in: context.cgContext)
            }
        }
        let png = try #require(image.pngData())
        Attachment.record(png, named: "replay-kept-over-unavailable.png")
        if let dir = ProcessInfo.processInfo.environment["CMUX_VISUAL_OUT"], !dir.isEmpty {
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try? png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("replay-kept-over-unavailable.png"))
        }
        // The state itself is pinned by ChatDrawsKeptNotLoadingTests.aFailedReadKeepsTheKeptRecording;
        // this one keeps what the screen draws for it.
        #expect(png.count > 0)
    }
}
#endif
