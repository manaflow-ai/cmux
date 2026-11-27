#if DEBUG && os(iOS)
import CmuxMobileAgentChat
import CmuxMobileDesign
import Foundation

/// DEBUG-only demo driver (`-CmuxMobileDemo chat-feed`): scrolls the Feed, expands
/// Show more, shows a live arrival, answers a three-item question inline,
/// replies inline, opens an event, streams a full agent turn (permission and
/// question answered), scrolls the transcript and walks the diff viewer.
/// Pauses are intentional pacing for the recording, not synchronization;
/// waits on agent state observe the store.
@MainActor
public struct FeedDemoScript {
    let director = DemoDirector.shared
    let feed = FeedStore.shared

    public init() {}

    /// `-CmuxMobileDemoHold <point>`: stop the script there ("chat" after the turn, "diff" in the file).
    private var hold: String? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-CmuxMobileDemoHold"), arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1]
    }

    public func run() async {
        func pause(_ seconds: Double) async { try? await Task.sleep(for: .seconds(seconds)) }
        func post(_ command: DemoDirector.Command, then seconds: Double) async {
            director.post(command)
            await pause(seconds)
        }
        await pause(2.0)
        await post(.feedScroll(toEvent: "f-math"), then: 2.4)
        await post(.feedScroll(toEvent: "f-long"), then: 1.4)
        await post(.feedExpand(event: "f-long"), then: 2.0)
        feed.injectLiveEvent(atTop: false)
        await pause(1.6)
        await post(.feedScrollTop, then: 1.6)
        await post(.answerQuestion(id: "feed-q-release", picks: [["rc"], ["transport", "feed", "diff"], ["yes"]]), then: 6.0)
        await post(.feedScroll(toEvent: "f-pricing"), then: 1.2)
        await post(.feedReply(event: "f-pricing", text: "Also check the annual toggle on iPad"), then: 3.4)
        await post(.feedOpen(event: "f-finished"), then: 1.8)
        guard let chat = AgentSessionDirectory.shared.existingStore(id: "t-claude") else { return }
        // t-claude opens in its waiting state (a pending question). Answer it and let that
        // turn finish, so the scripted prompt starts a fresh turn instead of queueing.
        if chat.pendingQuestion?.id == "q-waiting" {
            await post(.answerQuestion(id: "q-waiting", picks: [["webrtc"], ["connection"]]), then: 0.5)
        }
        await wait(seconds: 30) { !chat.isRunning }
        await pause(1.0)
        await post(.chatSend("Make the transport layer switchable between WebRTC and WireGuard, and add tests"), then: 3.0)
        await wait(seconds: 30) { chat.pendingPermission != nil }
        await pause(1.6)
        await post(.chatPermission(optionKind: "allow_once"), then: 0.5)
        await wait(seconds: 30) { chat.pendingQuestion != nil }
        await pause(1.4)
        await post(.answerQuestion(id: "q-transport", picks: [["wireguard"], ["connection", "per-mac"]]), then: 0.5)
        await wait(seconds: 40) { !chat.isRunning }
        await pause(2.0)
        if hold == "chat" { return }
        await post(.chatScroll(toTop: true), then: 2.6)
        await post(.chatScroll(toTop: false), then: 2.2)
        await post(.chatOpenFirstFile, then: 2.2)
        // `-CmuxMobileDemoHold diff` leaves the diff open for hand-driven captures.
        if hold == "diff" { return }
        await post(.diffExpandFirst, then: 1.6)
        await post(.diffSetSplit(true), then: 2.4)
        await post(.diffSetSplit(false), then: 1.0)
        await post(.diffMarkViewed, then: 1.6)
        await post(.navigateBack, then: 1.4)
        await post(.chatOpenChanges, then: 3.0)
    }

    /// Re-checks `condition` whenever the observed state changes, with a deadline.
    private func wait(seconds: Double, until condition: @escaping @MainActor () -> Bool) async {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition(), Date() < deadline {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                withObservationTracking {
                    _ = condition()
                } onChange: {
                    continuation.resume()
                }
            }
        }
    }
}
#endif
