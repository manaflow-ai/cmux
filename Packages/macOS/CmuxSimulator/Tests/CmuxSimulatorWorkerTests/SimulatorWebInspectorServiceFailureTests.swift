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

    private static func service() -> SimulatorWebInspectorService {
        SimulatorWebInspectorService(subprocessRunner: SimulatorSubprocessRunner())
    }

    private static func seedTarget(into service: SimulatorWebInspectorService) {
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
                    ],
                ],
            ],
        ], ownConnectionIdentifier: "OURS")
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
