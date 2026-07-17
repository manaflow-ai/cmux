import Darwin
import CmuxSimulator
import Foundation
import Testing
@testable import CmuxSimulatorWorker

@Suite("Web Inspector transport failure containment")
@MainActor
struct SimulatorWebInspectorServiceFailureTests {
    @Test("Raw commands cannot collide with internal request identifiers")
    func reservedRequestIdentifier() throws {
        let service = Self.service()
        service.session = SimulatorWebInspectorSession(
            identifier: UUID(),
            target: SimulatorWebInspectorTarget(
                id: "APP|7",
                applicationIdentifier: "APP",
                pageIdentifier: 7,
                title: "Fixture",
                url: "https://example.test",
                type: "WIRTypeWebPage",
                applicationName: "Fixture",
                bundleIdentifier: "com.example.fixture",
                isInUse: false
            ),
            senderIdentifier: "SENDER"
        )

        #expect(throws: SimulatorWebInspectorError.reservedIdentifier) {
            try service.sendMessageWithoutMutationGate(
                #"{"id":-9000000000000000,"method":"Runtime.enable"}"#
            )
        }
    }

    @Test("Refresh observes the first RPC send failure immediately")
    func refreshSendFailure() async {
        let service = Self.service()
        let transport = FailingWebInspectorTransport()
        service.socket = transport
        service.currentDeviceIdentifier = "DEVICE"

        do {
            _ = try await service.refreshTargets(deviceIdentifier: "DEVICE")
            Issue.record("Expected the failed transport write to end refresh")
        } catch let error as SimulatorWebInspectorError {
            #expect(error == .socketFailure(EPIPE))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(transport.sendCount == 1)
        #expect(service.refreshContinuation == nil)
        #expect(service.socket == nil)
    }

    @Test("Attach never reports attached after its setup write fails")
    func attachSendFailure() async {
        let service = Self.service()
        let transport = FailingWebInspectorTransport()
        service.socket = transport
        service.currentDeviceIdentifier = "DEVICE"
        Self.seedTarget(into: service)
        var attachedWasEmitted = false
        service.eventHandler = { event in
            guard case let .session(status) = event,
                  case .attached = status else { return }
            attachedWasEmitted = true
        }

        do {
            _ = try await service.attach(targetIdentifier: "APP|7")
            Issue.record("Expected the failed setup write to reject attachment")
        } catch let error as SimulatorWebInspectorError {
            #expect(error == .socketFailure(EPIPE))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(!attachedWasEmitted)
        #expect(service.session == nil)
        #expect(service.socket == nil)
    }

    @Test("Refresh observes failure after the identifier RPC succeeds")
    func secondRefreshSendFailure() async {
        let service = Self.service()
        let transport = FailingWebInspectorTransport(failAtSend: 2)
        service.socket = transport
        service.currentDeviceIdentifier = "DEVICE"

        do {
            _ = try await service.refreshTargets(deviceIdentifier: "DEVICE")
            Issue.record("Expected the second transport write to end refresh")
        } catch let error as SimulatorWebInspectorError {
            #expect(error == .socketFailure(EPIPE))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
        #expect(transport.sendCount == 2)
        #expect(service.refreshContinuation == nil)
    }

    @Test("Target publications coalesce and suppress duplicate snapshots")
    func targetPublicationCoalescing() async {
        let sleeper = ManualWebInspectorSleeper()
        let service = SimulatorWebInspectorService(
            subprocessRunner: SimulatorSubprocessRunner(),
            sleeper: sleeper
        )
        Self.seedTarget(into: service)
        var snapshots: [[SimulatorWebInspectorTarget]] = []
        service.eventHandler = { event in
            guard case let .targets(targets) = event else { return }
            snapshots.append(targets)
        }

        for _ in 0..<100 { service.scheduleTargetPublication() }
        await eventually { await sleeper.pendingCount == 1 }
        await sleeper.resumeAll()
        await eventually { snapshots.count == 1 }

        service.scheduleTargetPublication()
        await eventually { await sleeper.pendingCount == 1 }
        await sleeper.resumeAll()
        await eventually { service.targetPublicationTask == nil }
        #expect(snapshots.count == 1)
    }

    @Test("Two workers cannot attach to the same target concurrently")
    func targetLeaseSpansAttachedSession() async throws {
        let lockDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-web-inspector-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: lockDirectory) }
        let first = SimulatorWebInspectorService(
            subprocessRunner: SimulatorSubprocessRunner(),
            mutationGate: SimulatorMutationGate(lockDirectory: lockDirectory)
        )
        let second = SimulatorWebInspectorService(
            subprocessRunner: SimulatorSubprocessRunner(),
            mutationGate: SimulatorMutationGate(lockDirectory: lockDirectory)
        )
        let firstTransport = SuccessfulWebInspectorTransport(service: first)
        let secondTransport = SuccessfulWebInspectorTransport(service: second)
        first.socket = firstTransport
        second.socket = secondTransport
        first.currentDeviceIdentifier = "DEVICE"
        second.currentDeviceIdentifier = "DEVICE"
        Self.seedTarget(into: first)
        Self.seedTarget(into: second, isInUse: true)

        _ = try await first.attach(targetIdentifier: "APP|7")
        let secondAttach = Task { @MainActor in
            try await second.attach(targetIdentifier: "APP|7")
        }
        for _ in 0..<200 { await Task.yield() }
        #expect(second.session == nil)

        try await first.releaseSession()
        _ = try await secondAttach.value
        #expect(second.session != nil)
        second.shutdown()
    }

    @Test("Attach fails closed when the target occupancy listing times out")
    func attachRejectsIncompleteOccupancyRefresh() async throws {
        let sleeper = ManualWebInspectorSleeper()
        let service = SimulatorWebInspectorService(
            subprocessRunner: SimulatorSubprocessRunner(),
            sleeper: sleeper
        )
        let transport = SuccessfulWebInspectorTransport(
            service: service,
            respondsToCensus: false,
            respondsToListings: false
        )
        service.socket = transport
        service.currentDeviceIdentifier = "DEVICE"
        Self.seedTarget(into: service)

        let attach = Task { @MainActor in
            try await service.attach(targetIdentifier: "APP|7")
        }
        await eventually { await sleeper.pendingCount == 1 }
        transport.emitListing()
        for _ in 0..<100 { await Task.yield() }
        await sleeper.resumeAll()

        do {
            _ = try await attach.value
            Issue.record("Expected incomplete occupancy refresh to reject attachment")
        } catch let error as SimulatorWebInspectorError {
            guard case .timedOut = error else {
                Issue.record("Unexpected Web Inspector error: \(error)")
                return
            }
        }
        #expect(service.session == nil)
    }

    private static func service() -> SimulatorWebInspectorService {
        SimulatorWebInspectorService(subprocessRunner: SimulatorSubprocessRunner())
    }

    private static func seedTarget(
        into service: SimulatorWebInspectorService,
        isInUse: Bool = false
    ) {
        service.catalog.apply([
            "__selector": "_rpc_reportConnectedApplicationList:",
            "__argument": [
                "WIRApplicationDictionaryKey": [
                    "APP": [
                        "WIRApplicationBundleIdentifierKey": "com.example.app",
                        "WIRApplicationNameKey": "Example",
                    ],
                ],
            ],
        ], ownConnectionIdentifier: "OURS")
        service.catalog.apply([
            "__selector": "_rpc_applicationSentListing:",
            "__argument": [
                "WIRApplicationIdentifierKey": "APP",
                "WIRListingKey": [
                    "7": [
                        "WIRPageIdentifierKey": 7,
                        "WIRTitleKey": "Fixture",
                        "WIRURLKey": "https://example.test",
                        "WIRTypeKey": "WIRTypeWebPage",
                        "WIRConnectionIdentifierKey": isInUse ? "OTHER" : "",
                    ],
                ],
            ],
        ], ownConnectionIdentifier: "OURS")
    }
}

@MainActor
private final class SuccessfulWebInspectorTransport: SimulatorWebInspectorTransport {
    nonisolated let messages: AsyncStream<Data> = AsyncStream { _ in }
    weak var service: SimulatorWebInspectorService?
    let respondsToCensus: Bool
    let respondsToListings: Bool

    init(
        service: SimulatorWebInspectorService,
        respondsToCensus: Bool = true,
        respondsToListings: Bool = true
    ) {
        self.service = service
        self.respondsToCensus = respondsToCensus
        self.respondsToListings = respondsToListings
    }

    func send(propertyList: [String: Any]) throws {
        let selector = propertyList["__selector"] as? String
        if selector == "_rpc_getConnectedApplications:" {
            guard respondsToCensus else { return }
            deliver([
                "__selector": "_rpc_reportConnectedApplicationList:",
                "__argument": [
                    "WIRApplicationDictionaryKey": [
                        "APP": [
                            "WIRApplicationBundleIdentifierKey": "com.example.app",
                            "WIRApplicationNameKey": "Example",
                        ],
                    ],
                ],
            ])
            return
        }
        if selector == "_rpc_forwardGetListing:" {
            guard respondsToListings else { return }
            deliver([
                "__selector": "_rpc_applicationSentListing:",
                "__argument": [
                    "WIRApplicationIdentifierKey": "APP",
                    "WIRListingKey": [
                        "7": [
                            "WIRPageIdentifierKey": 7,
                            "WIRTitleKey": "Fixture",
                            "WIRURLKey": "https://example.test",
                            "WIRTypeKey": "WIRTypeWebPage",
                        ],
                    ],
                ],
            ])
            return
        }
        guard selector == "_rpc_forwardSocketData:",
              let argument = propertyList["__argument"] as? [String: Any],
              let request = argument["WIRSocketDataKey"] as? Data,
              let object = try JSONSerialization.jsonObject(with: request) as? [String: Any],
              let identifier = simulatorWebInspectorInteger(object["id"]),
              let service else { return }
        let response = try JSONSerialization.data(withJSONObject: [
            "id": identifier,
            "result": [:],
        ])
        deliver([
            "__selector": "_rpc_applicationSentData:",
            "__argument": [
                "WIRApplicationIdentifierKey": "APP",
                "WIRPageIdentifierKey": 7,
                "WIRDestinationKey": service.session?.senderIdentifier ?? "",
                "WIRMessageDataKey": response,
            ],
        ])
    }

    private func deliver(_ propertyList: [String: Any]) {
        guard let service,
              let body = try? SimulatorWebInspectorPlistFrameCodec().encodeBody(propertyList)
        else { return }
        Task { @MainActor [weak service] in
            service?.receive(propertyListBody: body)
        }
    }

    func close() {}

    func emitListing() {
        deliver([
            "__selector": "_rpc_applicationSentListing:",
            "__argument": [
                "WIRApplicationIdentifierKey": "APP",
                "WIRListingKey": [
                    "7": [
                        "WIRPageIdentifierKey": 7,
                        "WIRTitleKey": "Fixture",
                        "WIRURLKey": "https://example.test",
                        "WIRTypeKey": "WIRTypeWebPage",
                    ],
                ],
            ],
        ])
    }
}

private actor ManualWebInspectorSleeper: SimulatorWebInspectorSleeping {
    private var continuations: [CheckedContinuation<Void, Error>] = []

    var pendingCount: Int { continuations.count }

    func sleep(for duration: Duration) async throws {
        try await withCheckedThrowingContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func resumeAll() {
        let pending = continuations
        continuations.removeAll()
        for continuation in pending { continuation.resume() }
    }
}

@MainActor
private func eventually(
    _ predicate: @escaping @MainActor () async -> Bool
) async {
    for _ in 0..<10_000 {
        if await predicate() { return }
        await Task.yield()
    }
    Issue.record("Condition did not become true")
}
