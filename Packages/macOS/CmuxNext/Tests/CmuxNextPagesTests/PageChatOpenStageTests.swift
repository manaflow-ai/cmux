import CmuxNextCompat
@testable import CmuxNextPages
import CmuxNextPagesTestSupport
@testable import CmuxNextSignposts
@testable import CmuxNextTrace
import CmuxNextWakeups
import CmuxNextWakeupsTestSupport
import Testing
import WebKit

/// A page's chat open stages in every build (p09-observability task 044): a page made for an agent chat open
/// (``PageWebView/chatOpen``) writes each stage of its document as a `create.tab` instant on the open's intent id,
/// in either engine; a page made with no open writes none.
@MainActor @Suite(.serialized)
struct PageChatOpenStageTests {
    private let descriptor = PageDescriptor(id: "test.chat-open", resource: "chat-open", processGroup: .solo, namespaces: [])

    /// The `create.tab` records a test runtime writes, in order.
    nonisolated final class RecordLog: Sendable {
        private let state = Mutex<[TraceRuntime.StubRecord]>([])

        /// The stage of each chat stage instant, in order.
        var stages: [ChatOpenStage] {
            state.withLock { $0 }.filter { $0.phase == .instant && $0.arg0 & 0xFF == CreateTabInterval.Kind.chat.traceCode }
                .compactMap { ChatOpenStage(rawValue: Int($0.arg0 >> 8) - 1) }
        }

        /// The `arg1` of each chat stage instant.
        var ids: [UInt64] { state.withLock { $0 }.filter { $0.phase == .instant }.map(\.arg1) }

        /// An open timed on a runtime with the `create` category on, recording into this log.
        @MainActor func open() -> CreateTabInterval {
            let runtime = TraceRuntime(role: .app, clock: TraceClock(), stubRecorder: { [self] record in
                state.withLock { $0.append(record) }
            })
            runtime.setCategoryMask(1 << UInt64(SignpostCategory.create.traceBit))
            return CreateTabInterval(kind: .chat,
                                     signposter: Signposter(category: .create, mirror: SignpostMetricKitMirror(), trace: runtime))
        }
    }

    private func page(chatOpen: ChatOpenStages?, chromium: (any PageChromiumHosting)? = nil) -> PageWebView {
        let configuration = WKWebViewConfiguration()
        return PageWebView(descriptor: descriptor, configuration: configuration,
                           inputReadiness: PageInputReadiness(configuration: configuration), routes: [], route: nil,
                           options: .standard, surface: nil, dynamicResources: nil, pooled: false, load: true,
                           chromium: chromium, deadlines: .testing(), trace: PageTraceRecorder(), chatOpen: chatOpen)
    }

    @Test func aWebKitPageOfAnOpenWritesItsStagesOnTheIntentID() {
        let log = RecordLog()
        let open = log.open()
        let view = page(chatOpen: ChatOpenStages(open))
        view.documentCommitted()
        view.notePainted()
        view.close()
        #expect(log.stages == [.navigationStart, .committed, .pagePainted])
        #expect(log.ids.allSatisfy { $0 == open.intentID })
    }

    @Test func aChromiumPageOfAnOpenWritesItsChromiumStages() async {
        let log = RecordLog()
        let open = log.open()
        let view = page(chatOpen: ChatOpenStages(open), chromium: FakeChromiumHosting())
        view.chromiumDeadlines = LifecycleDeadlineRig.never
        await view.chromiumStart?.value
        view.close()
        #expect(Array(log.stages.prefix(4)) == [.chromiumStart, .browserCreated, .setupDone, .navigationStart])
        #expect(log.ids.allSatisfy { $0 == open.intentID })
    }

    @Test func aPageWithNoOpenWritesNoStage() {
        let log = RecordLog()
        let open = log.open()
        let view = page(chatOpen: nil)
        view.documentCommitted()
        view.notePainted()
        view.close()
        #expect(log.stages.isEmpty)
        open.end(.closed)
    }
}
