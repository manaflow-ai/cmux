import Foundation
import os
import Testing
@testable import CmuxMobileCloud
@testable import CmuxMobileCloudUI

@MainActor
@Suite struct CloudTerminalScreenModelTests {
    final class RecordingSurface: CloudTerminalScreenModel.Surface {
        enum Call: Equatable { case grid(Int, Int); case write(Data) }
        private(set) var calls: [Call] = []
        func writeOutput(_ data: Data) { calls.append(.write(data)) }
        func applyGrid(cols: Int, rows: Int) { calls.append(.grid(cols, rows)) }
    }

    final class ScriptedService: CloudVMServing, @unchecked Sendable {
        func listMachines() async throws -> [CloudMachine] { [] }
        func enrollTunnel(clientPublicKey: String, deviceFingerprint: String, deviceName: String?) async throws -> CloudTunnelEnrollment { throw StubError(message: "unused") }
        func openAttach(machineID: String, deviceFingerprint: String) async throws -> CloudAttachEndpoint {
            CloudAttachEndpoint(route: "ws://h/v1/link", session: "s")
        }
        func approveEnrollment(machineID: String, invitationId: String) async throws -> Bool { true }
    }

    private func makeConnection(failure: (any Error)? = nil) -> (CloudMachineConnection, FakeConnector) {
        let connector = FakeConnector()
        connector.failure = failure
        let connection = CloudMachineConnection(
            machine: CloudMachine(id: "vm1", provider: "p", status: "running"),
            service: ScriptedService(),
            connector: connector,
            tunnel: FakeTunnel(config: "x"),
            identity: CloudDeviceIdentity.mint(),
            stateDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),
            deviceName: "phone",
            approvalClock: ContinuousClock()
        )
        return (connection, connector)
    }

    private func settle(_ condition: @MainActor () -> Bool) async {
        for _ in 0 ..< 3_000 where !condition() { await Task.yield() }
    }

    @Test func snapshotThenOutputReachTheSurfaceInOrder() async throws {
        let (connection, connector) = makeConnection()
        let model = CloudTerminalScreenModel()
        let surface = RecordingSurface()
        model.setSurface(surface)
        await model.attach(connection: connection, terminalID: "t1")
        #expect(model.phase == .attached)

        let handler = try #require(connector.session.outputHandler)
        handler(.snapshot(replay: Data("$ ".utf8), cols: 80, rows: 24))
        handler(.output(Data("ls\r\n".utf8)))
        await settle { surface.calls.count == 3 }
        #expect(surface.calls == [.grid(80, 24), .write(Data("$ ".utf8)), .write(Data("ls\r\n".utf8))])
    }

    @Test func outputBeforeSurfaceIsReplayedOnceItMounts() async throws {
        let (connection, connector) = makeConnection()
        let model = CloudTerminalScreenModel()
        await model.attach(connection: connection, terminalID: "t1")
        let handler = try #require(connector.session.outputHandler)
        handler(.snapshot(replay: Data("boot".utf8), cols: 90, rows: 30))
        for _ in 0 ..< 200 { await Task.yield() }
        let surface = RecordingSurface()
        model.setSurface(surface)
        #expect(surface.calls == [.grid(90, 30), .write(Data("boot".utf8))])
    }

    @Test func exitEventMovesToExitedPhase() async throws {
        let (connection, connector) = makeConnection()
        let model = CloudTerminalScreenModel()
        model.setSurface(RecordingSurface())
        await model.attach(connection: connection, terminalID: "t1")
        let handler = try #require(connector.session.outputHandler)
        handler(.exited)
        await settle { model.phase == .exited }
        #expect(model.phase == .exited)
    }

    @Test func inputAndResizeForwardToTheAttachment() async {
        let (connection, connector) = makeConnection()
        let model = CloudTerminalScreenModel()
        model.setSurface(RecordingSurface())
        await model.attach(connection: connection, terminalID: "t1")
        model.sendInput(Data("q".utf8))
        model.reportGrid(cols: 50, rows: 10)
        model.reportGrid(cols: 0, rows: 0)
        model.detach()
        let state = connector.session.state
        #expect(state.sent == [Data("q".utf8)])
        #expect(state.resizes.map { [$0.0, $0.1] } == [[50, 10]])
        #expect(state.detached == 1)
    }

    @Test func attachFailureIsClassifiedAsLink() async {
        let (connection, _) = makeConnection(failure: StubError(message: "no route"))
        let model = CloudTerminalScreenModel()
        model.setSurface(RecordingSurface())
        await model.attach(connection: connection, terminalID: "t1")
        guard case .failed(let failure) = model.phase else { Issue.record("expected failure"); return }
        #expect(failure.kind == .link)
    }
}
