#if os(iOS)
import Foundation
import os
@testable import CmuxMobileCloud

struct StubError: Error, Equatable { let message: String }

final class FakeTunnel: CloudTunnel {
    let config: String
    init(config: String) { self.config = config }
}

final class FakeTerminalSession: CloudTerminalSession, @unchecked Sendable {
    struct State {
        var attached: String?
        var sent: [Data] = []
        var resizes: [(Int, Int)] = []
        var detached = 0
        var disconnected = 0
    }
    private let lock = OSAllocatedUnfairLock(initialState: State())
    var state: State { lock.withLock { $0 } }
    private let handlerBox = OSAllocatedUnfairLock<(@Sendable (CloudTerminalOutputEvent) -> Void)?>(initialState: nil)
    var outputHandler: (@Sendable (CloudTerminalOutputEvent) -> Void)? { handlerBox.withLock { $0 } }

    func listTerminals() async throws -> [CloudTerminalSummary] { [CloudTerminalSummary(id: "t1", name: "shell")] }
    func createTerminal(name: String?) async throws -> String { "t2" }
    func attach(terminalID: String, output: @escaping @Sendable (CloudTerminalOutputEvent) -> Void) async throws {
        lock.withLock { $0.attached = terminalID }
        handlerBox.withLock { $0 = output }
    }
    func detach() { lock.withLock { $0.detached += 1 } }
    func send(_ bytes: Data) { lock.withLock { $0.sent.append(bytes) } }
    func resize(cols: Int, rows: Int) { lock.withLock { $0.resizes.append((cols, rows)) } }
    func disconnect() { lock.withLock { $0.disconnected += 1 } }
}

final class FakeConnector: CloudTerminalConnecting, @unchecked Sendable {
    let session = FakeTerminalSession()
    var failure: (any Error)?
    func connect(route: String, stateDirectory: URL, deviceName: String, invitation: String?, tunnel: (any CloudTunnel)?) async throws -> any CloudTerminalSession {
        if let failure { throw failure }
        return session
    }
}
