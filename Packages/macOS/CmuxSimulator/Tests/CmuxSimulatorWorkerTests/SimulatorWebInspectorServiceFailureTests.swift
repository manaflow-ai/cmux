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
