@testable import CmuxSudoBrokerUI
import CmuxSudoBroker
import Foundation
import Testing

@Suite("Sudo approval coordinator")
@MainActor
struct SudoApprovalCoordinatorTests {
    @Test("Startup presents an exact snapshot and decisions use the broker")
    func startupAndApprovalUseInjectedBoundaries() async throws {
        let snapshot = SudoPendingRequest(
            request: SudoRequest(
                id: "request-1",
                reason: "Install helper",
                requesterPid: 123,
                requesterCommand: "cmux",
                currentDirectory: "/tmp/project",
                createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                timeoutSeconds: 300
            ),
            script: "echo reviewed\n"
        )
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
}

private actor RecordingSudoBroker: SudoBrokerServing {
    private let initialSnapshots: [SudoPendingRequest]
    private let eventStream: AsyncStream<SudoBrokerEvent>
    private var approvedIDs: [String] = []
    private var stops = 0

    init(initialSnapshots: [SudoPendingRequest]) {
        self.initialSnapshots = initialSnapshots
        eventStream = AsyncStream { _ in }
    }

    var approvedRequestIDs: [String] { approvedIDs }
    var stopCallCount: Int { stops }

    func events() -> AsyncStream<SudoBrokerEvent> { eventStream }
    func start() -> [SudoPendingRequest] { initialSnapshots }

    func approve(id: String) {
        approvedIDs.append(id)
    }

    func deny(id: String) {}

    func stop() {
        stops += 1
    }
}

@MainActor
private final class RecordingSudoApprovalPresenter: SudoApprovalPresenting {
    private(set) var presentations: [String: SudoApprovalPresentation] = [:]
    private(set) var dismissAllCallCount = 0

    func present(
        _ presentation: SudoApprovalPresentation,
        approve: @MainActor @Sendable @escaping () async -> Void,
        deny: @MainActor @Sendable @escaping () async -> Void
    ) {
        presentations[presentation.request.id] = presentation
    }

    func dismiss(id: String) {
        presentations.removeValue(forKey: id)
    }

    func dismissAll() {
        dismissAllCallCount += 1
        presentations.removeAll()
    }
}
