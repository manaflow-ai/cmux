@testable import CmuxSudoBrokerUI
import CmuxSudoBroker
import Foundation
import Testing

@Suite("Sudo approval coordinator")
@MainActor
struct SudoApprovalCoordinatorTests {
    @Test("Startup presents an exact snapshot and decisions use the broker")
    func startupAndApprovalUseInjectedBoundaries() async throws {
        let snapshot = Self.snapshot(id: "request-1")
        let broker = RecordingSudoBroker(initialSnapshots: [snapshot])
        let presenter = RecordingSudoApprovalPresenter()
        let coordinator = SudoApprovalCoordinator(broker: broker, presenter: presenter)

        try await coordinator.start()

        let presentation = try #require(presenter.presentations["request-1"])
        #expect(presentation.request == snapshot.request)
        #expect(presentation.script == snapshot.script)
        #expect(presentation.canDecide)

        await coordinator.approve(id: "request-1")

        #expect(await broker.approvedRequestIDs == ["request-1"])
        #expect(!presentation.canDecide)

        await coordinator.stop()
        #expect(presenter.dismissAllCallCount == 1)
        #expect(await broker.stopCallCount == 1)
    }

    @Test("Phase and settlement events update then dismiss the presentation")
    func lifecycleEventsProjectAuthoritativeState() async throws {
        let snapshot = Self.snapshot(id: "request-events")
        let broker = RecordingSudoBroker(initialSnapshots: [snapshot])
        let presenter = RecordingSudoApprovalPresenter()
        let coordinator = SudoApprovalCoordinator(broker: broker, presenter: presenter)
        var presenterEvents = presenter.events.makeAsyncIterator()

        try await coordinator.start()
        #expect(await presenterEvents.next() == .presented("request-events"))
        let presentation = try #require(presenter.presentations["request-events"])

        await broker.send(
            .snapshot([
                SudoPendingRequest(
                    request: snapshot.request,
                    script: snapshot.script,
                    phase: .approved
                )
            ])
        )
        await broker.send(.snapshot([]))

        #expect(await presenterEvents.next() == .dismissed("request-events"))
        #expect(presentation.phase == .approved)
        #expect(coordinator.presentations["request-events"] == nil)
        await coordinator.stop()
    }

    @Test("A replacement snapshot repairs skipped intermediate events")
    func replacementSnapshotReconcilesAdditionsAndRemovals() async throws {
        let first = Self.snapshot(id: "request-first")
        let second = SudoPendingRequest(
            request: Self.snapshot(id: "request-second").request,
            script: "echo second\n",
            phase: .executing
        )
        let broker = RecordingSudoBroker(initialSnapshots: [first])
        let presenter = RecordingSudoApprovalPresenter()
        let coordinator = SudoApprovalCoordinator(broker: broker, presenter: presenter)
        var events = presenter.events.makeAsyncIterator()
        try await coordinator.start()
        #expect(await events.next() == .presented(first.request.id))

        await broker.send(.snapshot([second]))

        #expect(await events.next() == .dismissed(first.request.id))
        #expect(await events.next() == .presented(second.request.id))
        #expect(coordinator.presentations[first.request.id] == nil)
        #expect(coordinator.presentations[second.request.id]?.phase == .executing)
        await coordinator.stop()
    }

    @Test("A request can be denied only once")
    func denialIsSingleShot() async throws {
        let snapshot = Self.snapshot(id: "request-deny")
        let broker = RecordingSudoBroker(initialSnapshots: [snapshot])
        let coordinator = SudoApprovalCoordinator(
            broker: broker,
            presenter: RecordingSudoApprovalPresenter()
        )
        try await coordinator.start()

        await coordinator.deny(id: "request-deny")
        await coordinator.deny(id: "request-deny")

        #expect(await broker.deniedRequestIDs == ["request-deny"])
        await coordinator.stop()
    }

    @Test("Shutdown joins startup and never presents a late snapshot")
    func shutdownDuringStartup() async throws {
        let broker = BlockingStartSudoBroker(snapshot: Self.snapshot(id: "request-late"))
        let presenter = RecordingSudoApprovalPresenter()
        let coordinator = SudoApprovalCoordinator(broker: broker, presenter: presenter)
        var startEvents = await broker.startEvents().makeAsyncIterator()

        coordinator.start { error in
            Issue.record("Unexpected startup failure: \(error)")
        }
        _ = await startEvents.next()
        await coordinator.stop()

        #expect(presenter.presentations.isEmpty)
        #expect(await broker.stopCallCount == 1)
    }

    @Test("A restart requested during shutdown begins only after shutdown joins")
    func restartAfterCancelledTermination() async {
        let broker = BlockingStopSudoBroker()
        let coordinator = SudoApprovalCoordinator(
            broker: broker,
            presenter: RecordingSudoApprovalPresenter()
        )
        var startEvents = await broker.startEvents().makeAsyncIterator()
        var stopEvents = await broker.stopEvents().makeAsyncIterator()

        coordinator.start { error in
            Issue.record("Unexpected initial startup failure: \(error)")
        }
        _ = await startEvents.next()
        let stopTask = Task { await coordinator.stop() }
        _ = await stopEvents.next()

        coordinator.start { error in
            Issue.record("Unexpected restart failure: \(error)")
        }
        #expect(await broker.startCallCount == 1)
        await broker.releaseFirstStop()
        await stopTask.value
        _ = await startEvents.next()

        #expect(await broker.startCallCount == 2)
        await coordinator.stop()
    }

    private static func snapshot(id: String) -> SudoPendingRequest {
        SudoPendingRequest(
            request: SudoRequest(
                id: id,
                reason: "Install helper",
                requesterPid: 123,
                requesterCommand: "cmux",
                currentDirectory: "/tmp/project",
                createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                timeoutSeconds: 300
            ),
            script: "echo reviewed\n"
        )
    }
}

private actor RecordingSudoBroker: SudoBrokerServing {
    private let initialSnapshots: [SudoPendingRequest]
    private let eventStream: AsyncStream<SudoBrokerEvent>
    private var approvedIDs: [String] = []
    private var deniedIDs: [String] = []
    private var stops = 0
    private let eventContinuation: AsyncStream<SudoBrokerEvent>.Continuation

    init(initialSnapshots: [SudoPendingRequest]) {
        self.initialSnapshots = initialSnapshots
        let pair = AsyncStream.makeStream(of: SudoBrokerEvent.self)
        eventStream = pair.stream
        eventContinuation = pair.continuation
    }

    var approvedRequestIDs: [String] { approvedIDs }
    var deniedRequestIDs: [String] { deniedIDs }
    var stopCallCount: Int { stops }

    func events() -> AsyncStream<SudoBrokerEvent> { eventStream }
    func start() -> [SudoPendingRequest] { initialSnapshots }

    func approve(id: String) {
        approvedIDs.append(id)
    }

    func deny(id: String) {
        deniedIDs.append(id)
    }

    func send(_ event: SudoBrokerEvent) {
        eventContinuation.yield(event)
    }

    func stop() {
        stops += 1
    }
}

private actor BlockingStartSudoBroker: SudoBrokerServing {
    private let snapshot: SudoPendingRequest
    private let eventStream: AsyncStream<SudoBrokerEvent>
    private let startEventStream: AsyncStream<Void>
    private let startEventContinuation: AsyncStream<Void>.Continuation
    private var startContinuation: CheckedContinuation<Void, Never>?
    private var stops = 0

    init(snapshot: SudoPendingRequest) {
        self.snapshot = snapshot
        eventStream = AsyncStream { _ in }
        let pair = AsyncStream.makeStream(of: Void.self)
        startEventStream = pair.stream
        startEventContinuation = pair.continuation
    }

    var stopCallCount: Int { stops }

    func startEvents() -> AsyncStream<Void> { startEventStream }
    func events() -> AsyncStream<SudoBrokerEvent> { eventStream }

    func start() async -> [SudoPendingRequest] {
        startEventContinuation.yield()
        await withCheckedContinuation { continuation in
            startContinuation = continuation
        }
        return [snapshot]
    }

    func approve(id: String) {}
    func deny(id: String) {}

    func stop() {
        stops += 1
        startContinuation?.resume()
        startContinuation = nil
    }
}

private actor BlockingStopSudoBroker: SudoBrokerServing {
    private let eventStream: AsyncStream<SudoBrokerEvent>
    private let startEventStream: AsyncStream<Void>
    private let startEventContinuation: AsyncStream<Void>.Continuation
    private let stopEventStream: AsyncStream<Void>
    private let stopEventContinuation: AsyncStream<Void>.Continuation
    private var firstStopContinuation: CheckedContinuation<Void, Never>?
    private var starts = 0
    private var stops = 0

    init() {
        eventStream = AsyncStream { _ in }
        let startPair = AsyncStream.makeStream(of: Void.self)
        startEventStream = startPair.stream
        startEventContinuation = startPair.continuation
        let stopPair = AsyncStream.makeStream(of: Void.self)
        stopEventStream = stopPair.stream
        stopEventContinuation = stopPair.continuation
    }

    var startCallCount: Int { starts }

    func startEvents() -> AsyncStream<Void> { startEventStream }
    func stopEvents() -> AsyncStream<Void> { stopEventStream }
    func events() -> AsyncStream<SudoBrokerEvent> { eventStream }

    func start() -> [SudoPendingRequest] {
        starts += 1
        startEventContinuation.yield()
        return []
    }

    func approve(id: String) {}
    func deny(id: String) {}

    func stop() async {
        stops += 1
        stopEventContinuation.yield()
        guard stops == 1 else { return }
        await withCheckedContinuation { continuation in
            firstStopContinuation = continuation
        }
    }

    func releaseFirstStop() {
        firstStopContinuation?.resume()
        firstStopContinuation = nil
    }
}

@MainActor
private final class RecordingSudoApprovalPresenter: SudoApprovalPresenting {
    enum Event: Equatable {
        case presented(String)
        case dismissed(String)
        case dismissedAll
    }

    private(set) var presentations: [String: SudoApprovalPresentation] = [:]
    private(set) var dismissAllCallCount = 0
    let events: AsyncStream<Event>
    private let eventContinuation: AsyncStream<Event>.Continuation

    init() {
        let pair = AsyncStream.makeStream(of: Event.self)
        events = pair.stream
        eventContinuation = pair.continuation
    }

    func present(
        _ presentation: SudoApprovalPresentation,
        approve: @MainActor @Sendable @escaping () async -> Void,
        deny: @MainActor @Sendable @escaping () async -> Void
    ) {
        presentations[presentation.request.id] = presentation
        eventContinuation.yield(.presented(presentation.request.id))
    }

    func dismiss(id: String) {
        presentations.removeValue(forKey: id)
        eventContinuation.yield(.dismissed(id))
    }

    func dismissAll() {
        dismissAllCallCount += 1
        presentations.removeAll()
        eventContinuation.yield(.dismissedAll)
    }
}
