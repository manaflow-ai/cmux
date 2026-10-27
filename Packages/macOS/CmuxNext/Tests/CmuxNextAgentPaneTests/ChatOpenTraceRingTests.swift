import AppKit
@testable import CmuxNextAgentPane
import CmuxNextCompat
@testable import CmuxNextSignposts
@testable import CmuxNextTrace
import CmuxNextWakeups
import Testing

/// A chat open's stages in every build (p09-observability task 044): each is one `create.tab` instant of the chat
/// kind with its stage, on the open's intent id (the id of its `create.tab` pair), every time it happens, with no
/// `debug.chat_open_trace` armed. Content made with no open writes nothing.
@MainActor @Suite(.serialized)
struct ChatOpenTraceRingTests {
    /// The records a test runtime writes, in order.
    nonisolated final class RecordLog: Sendable {
        private let state = Mutex<[TraceRuntime.StubRecord]>([])

        var records: [TraceRuntime.StubRecord] { state.withLock { $0 } }

        /// The chat stage instants, in order (the pair's AB and AE left out).
        var stages: [TraceRuntime.StubRecord] {
            records.filter { $0.phase == .instant && $0.arg0 & 0xFF == CreateTabInterval.Kind.chat.traceCode && $0.arg0 >> 8 != 0 }
        }

        /// A `create` signposter on a runtime recording into this log, with only `categories` on.
        func signposter(_ categories: [SignpostCategory] = [.create]) -> (Signposter, TraceRuntime) {
            let runtime = TraceRuntime(role: .app, clock: TraceClock(), stubRecorder: { [self] record in
                state.withLock { $0.append(record) }
            })
            runtime.setCategoryMask(categories.reduce(UInt64(0)) { $0 | 1 << UInt64($1.traceBit) })
            return (Signposter(category: .create, mirror: SignpostMetricKitMirror(), trace: runtime), runtime)
        }
    }

    private actor NoHost: AgentPaneHostProviding {
        func handshake(sessionId: String?) async throws -> AgentPaneHandshake { throw AgentPaneHostError.daemonStopped }
    }

    private static let chat = CreateTabInterval.Kind.chat.traceCode

    private static func code(_ stage: ChatOpenStage) -> UInt64 { chat | stage.traceCode << 8 }

    @Test("Each stage is a create.tab instant of the chat kind on the open's intent id, every time")
    func eachStageIsAnInstantOnTheIntentID() {
        let log = RecordLog()
        let interval = CreateTabInterval(kind: .chat, signposter: log.signposter().0)
        let stages = ChatOpenStages(interval)
        #expect(stages.intentID == interval.intentID)
        stages.mark(.paneMade)
        stages.mark(.committed)
        stages.mark(.committed)  // a repeat (a reload's commit): written too
        interval.end(.shown)
        stages.mark(.loadingLeft)  // the cover's fade ends after the first paint: same id
        let written = log.stages
        #expect(written.map(\.arg0) == [ChatOpenStage.paneMade, .committed, .committed, .loadingLeft].map(Self.code))
        #expect(written.allSatisfy { $0.name == SignpostName.createTab.rawValue })
        #expect(written.allSatisfy { $0.arg1 == interval.intentID }, "every stage names the open's pair")
        #expect(log.records.first?.phase == .asyncBegin && log.records.first?.arg1 == interval.intentID)
    }

    @Test("An open begun with the create category off writes no stage, even once the category is on")
    func anUntracedOpenWritesNoStage() {
        let log = RecordLog()
        let (signposter, runtime) = log.signposter([.burst])
        let interval = CreateTabInterval(kind: .chat, signposter: signposter)
        runtime.setCategoryMask(1 << UInt64(SignpostCategory.create.traceBit))
        ChatOpenStages(interval).mark(.pagePainted)
        #expect(log.records.isEmpty)
    }

    @Test("A tab's chat open is found by its tab key while it waits for its first frame, under its new key too")
    func theTabStoreFindsTheOpenByItsTabKey() {
        let log = RecordLog()
        let timings = CreateTabTimings(signposter: log.signposter().0, afterCommit: { _ in })
        let chat = timings.begin(.chat)
        timings.expect(chat, tab: "provisional", standIn: false)
        #expect(ChatOpenStages(chat: timings.interval(ofTab: "provisional"))?.intentID == chat.intentID)
        timings.rekey("provisional", to: "tab_1")
        #expect(ChatOpenStages(chat: timings.interval(ofTab: "tab_1"))?.intentID == chat.intentID)
        let terminal = timings.begin(.terminal)
        timings.expect(terminal, tab: "tab_2", standIn: false)
        #expect(ChatOpenStages(chat: timings.interval(ofTab: "tab_2")) == nil, "another kind's open has no chat stages")
        timings.released("tab_1")
        #expect(timings.interval(ofTab: "tab_1") == nil)
        timings.released("tab_2")
    }

    @Test("A stage instant never reads as the stand-in commit's: its stage bits are never 0")
    func stagesAreNotTheStandIn() {
        let codes = ChatOpenStage.allCases.map(\.traceCode)
        #expect(codes == Array(1...UInt64(codes.count)))
        #expect(codes.allSatisfy { $0 <= 0xFF })
    }

    @Test("A pane made for an open writes its own and its page's stages on the open's id; its cover's leave too")
    func aPaneMadeForAnOpenWritesItsStages() throws {
        let log = RecordLog()
        let interval = CreateTabInterval(kind: .chat, signposter: log.signposter().0)
        let model = AgentPaneModel(host: NoHost())
        model.chatOpen = ChatOpenStages(interval)
        let file = try #require(AgentPageTestRoot.page)
        let view = try #require(AgentPaneView(mainThread: .standalone(), model: model, work: BackgroundWork(label: "test.agent-pane"), source: .bundled(file), webUI: .agentPaneTestHost(),
                                              gestures: .testing()))
        #expect(view.page.chatOpen?.intentID == interval.intentID, "the page is made with the open")
        // Not visible: the cover leaves in this turn, with no fade.
        view.alphaValue = 0
        view.endLoadingState()
        let written = log.stages
        #expect(written.allSatisfy { $0.arg1 == interval.intentID })
        let paneStages = written.map(\.arg0).filter { [ChatOpenStage.paneMade, .panePainted, .loadingLeave, .loadingLeft].map(Self.code).contains($0) }
        #expect(paneStages == [ChatOpenStage.paneMade, .panePainted, .loadingLeave, .loadingLeft].map(Self.code))
        view.page.close()
    }

    @Test("A pane made with no open writes nothing until an open adopts it; then its stages are that open's")
    func aSpareWritesOnlyOnceAdopted() throws {
        let log = RecordLog()
        let interval = CreateTabInterval(kind: .chat, signposter: log.signposter().0)
        let file = try #require(AgentPageTestRoot.page)
        let view = try #require(AgentPaneView(mainThread: .standalone(), model: AgentPaneModel(host: NoHost()), work: BackgroundWork(label: "test.agent-pane"), source: .bundled(file),
                                              webUI: .agentPaneTestHost(), gestures: .testing()))
        #expect(log.stages.isEmpty)
        view.join(ChatOpenStages(interval))
        view.alphaValue = 0
        view.endLoadingState()
        #expect(view.page.chatOpen?.intentID == interval.intentID)
        #expect(log.stages.map(\.arg0) == [ChatOpenStage.paneMade, .panePainted, .loadingLeave, .loadingLeft].map(Self.code))
        #expect(log.stages.allSatisfy { $0.arg1 == interval.intentID })
        view.page.close()
    }
}
