public import CmuxNextDesign
import struct CmuxNextControl.LaunchPriorChat
public import CmuxNextWakeups

/// The launch's second gate: it opens when the front chat drew live (`agent_pane.page_painted`, the page's own app, not
/// its saved copy) or, when the front is not a chat, a New Tab page drew (`agent_pane.newtab_painted`), or `backstop`
/// after the first frame (a terminal or Home front draws no chat; Home's own marks go through DebugTimings, not this
/// listener). Launch steps no chat needs wait on it, so they do not share the main thread with the chat page's first
/// navigation, handshake and paint: on the 2026-11-24/25 nightlies that navigation came 300-700 ms after its browser
/// when those steps ran beside it, 50-90 ms when they had run before it (research:startup:2026-11-25).
/// Not `agent_pane.painted`: a relaunched chat's saved copy reports it (`chatSnapshot/live.ts`, `copy: true`) about
/// 400 ms before the live chat, and opening there started the New Tab spare's page load and the other steps inside
/// the live chat's handshake, connect and paint (cmux#55313: `newtab_painted` 1374, `page_painted` 1520; goal
/// restart-to-chat). The New Tab spare itself starts behind this gate (`tab_warmups`), so its paint never opens it.
/// Not a New Tab paint once the front is a chat (`launch.front_chat_shown`, marked when the front chat's view enters
/// its window, ~440 ms): a New Tab page restored in another pane or workspace paints first (~1350 ms on the cmux#58024
/// bench) and opened the gate ~200 ms before the live front chat drew (~1570 ms), so the steps ran inside it again.
@MainActor
public struct FrontChatPaintGate {
    public init() {}
    nonisolated static let chatPaint = "agent_pane.page_painted"
    nonisolated static let newTabPaint = "agent_pane.newtab_painted"
    nonisolated static let frontIsChat = LaunchPriorChat.frontMark
    nonisolated static let marks: Set<String> = [chatPaint, newTabPaint, frontIsChat]

    /// Whether the launch's front tab is a chat, heard on the main thread in mark order.
    @MainActor final class Front {
        var isChat = false
    }

    public static func make(after firstFrame: FirstFrameGate, backstop: Duration = .milliseconds(1500),
                            timings: AgentPaneLaunchTimings = .shared,
                            timer: DemandTimer = DemandTimer(owner: "FrontChatPaintGate.backstop")) -> FirstFrameGate {
        let gate = FirstFrameGate(backstop: timer)
        let front = Front()
        timings.listen { name in
            guard marks.contains(name) else { return }
            MainDelivery().run {
                switch name {
                case frontIsChat: front.isChat = true
                case newTabPaint where front.isChat: break
                default: gate.open()
                }
            }
        }
        firstFrame.whenOpen { gate.armBackstop(after: backstop) }
        return gate
    }
}
