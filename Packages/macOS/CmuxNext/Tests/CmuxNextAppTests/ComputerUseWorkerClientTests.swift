// SPDX-License-Identifier: GPL-3.0-or-later
import Darwin
import Foundation
import Testing
@testable import CmuxNextComputerUse
import CmuxNextSettings

/// Review 1 #1, the app's half: the worker's mode and client are fixed when it starts (the
/// helper's environment, or cmux Remote's channel open, which the host turns into the worker's
/// environment once the client matches the app's signature: RemoteHostProcessTests). The client
/// is the one the approval broker answers for, so the worker's questions are admitted; a worker
/// that reports another client or mode is not used. The configure line no longer carries them.
@MainActor struct ComputerUseWorkerClientTests {
    nonisolated static let client = "com.cmuxterm.app.debug.cuclient"

    /// cmux Remote as the app sees it: records each open and serves the channel's other end as a
    /// worker that reports `reported(mode, client)` in its ready line.
    final class FakeRemote: ComputerUseRemoteSpawning, @unchecked Sendable { // crash-allow: test fake, fields under `lock`
        private let lock = NSLock()
        private var _opens: [(ComputerUseMode, String)] = []
        private var _configure: [String: Any]?
        private var workerEnds: [Int32] = []
        let reported: @Sendable (ComputerUseMode, String) -> (mode: String, client: String)

        init(reported: @escaping @Sendable (ComputerUseMode, String) -> (mode: String, client: String) = { ($0.rawValue, $1) }) {
            self.reported = reported
        }

        var opens: [(ComputerUseMode, String)] { lock.withLock { _opens } }
        var configure: [String: Any]? { lock.withLock { _configure } }

        func isAvailable() async -> Bool { true }

        func openComputerUse(mode: ComputerUseMode, client: String) async throws -> ComputerUseRemoteChannel {
            var pair: [Int32] = [-1, -1]
            guard socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0 else { throw CocoaError(.fileWriteUnknown) }
            lock.withLock {
                _opens.append((mode, client))
                workerEnds.append(pair[1])
            }
            let worker = pair[1]
            let report = reported(mode, client)
            // The worker: reads configure, answers ready with the mode and client it was started with.
            Thread.detachNewThread { [self] in
                var line = Data()
                var byte: UInt8 = 0
                while read(worker, &byte, 1) == 1, byte != 10 { line.append(byte) }
                let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any]
                lock.withLock { _configure = object }
                let ready = ComputerUseHelperV2.line(["type": "ready", "protocol": 1, "pid": Int(getpid()),
                                                      "socket": object?["socket"] as? String ?? "",
                                                      "permission_mode": report.mode, "client": report.client])
                _ = ready.withUnsafeBytes { write(worker, $0.baseAddress, $0.count) }
            }
            return ComputerUseRemoteChannel(pid: getpid(), socket: pair[0], executable: URL(fileURLWithPath: "/test/cmux-remote"))
        }

        func closeWorkers() {
            for end in lock.withLock({ workerEnds }) { close(end) }
        }
    }

    static func helper(remote: FakeRemote, directory: URL, mode: ComputerUseMode) -> (ComputerUseHelperV2, ComputerUseApprovalBroker) {
        let helper = ComputerUseHelperV2(directory: directory.path, helperApp: { nil }, acpmux: { nil },
                                         staging: .passing(root: directory))
        let store = ComputerUseApprovalStore(file: .standard(client: client, support: directory.appending(path: "support")))
        let now = ComputerUseApprovalTests.nowMs
        let broker = ComputerUseApprovalBroker(store: store, nowMs: { now })
        helper.approvals = broker
        helper.permissionMode = { mode }
        helper.remote = remote
        return (helper, broker)
    }

    static func directory() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "cu-client-\(UUID().uuidString.prefix(8))")
    }

    @Test(.timeLimit(.minutes(1))) func theWorkerStartsForTheBrokersClientAndItsQuestionsAreAdmitted() async throws {
        let directory = Self.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let remote = FakeRemote()
        defer { remote.closeWorkers() }
        let (helper, broker) = Self.helper(remote: remote, directory: directory, mode: .standard)

        await helper.apply(enabled: true)
        defer { helper.terminateForQuit() }

        // The open carries the mode and the broker's client; configure no longer does.
        let open = try #require(remote.opens.first)
        #expect(open.0 == .standard)
        #expect(open.1 == Self.client)
        #expect(helper.stateName == "running")
        let configure = try #require(remote.configure)
        #expect(configure["type"] as? String == "configure")
        #expect(configure["client"] == nil && configure["permission_mode"] == nil)

        // A question the worker sends carries that client: the broker admits it.
        let question = try ComputerUseApprovalTests.request(ComputerUseApprovalTests.requestObject(client: open.1))
        #expect(broker.admits(question, now: ComputerUseApprovalTests.nowMs))
        let unknown = try ComputerUseApprovalTests.request(ComputerUseApprovalTests.requestObject(client: "unknown"))
        #expect(!broker.admits(unknown, now: ComputerUseApprovalTests.nowMs))
    }

    @Test(.timeLimit(.minutes(1)), arguments: [("standard", "unknown"), ("ask", ComputerUseWorkerClientTests.client)])
    func aWorkerRunningForAnotherClientOrModeIsNotUsed(reportedMode: String, reportedClient: String) async throws {
        let directory = Self.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let remote = FakeRemote(reported: { _, _ in (reportedMode, reportedClient) })
        defer { remote.closeWorkers() }
        let (helper, _) = Self.helper(remote: remote, directory: directory, mode: .standard)

        await helper.apply(enabled: true)
        defer { helper.terminateForQuit() }
        #expect(helper.stateName == "unavailable")
    }

    @Test func theLocalHelpersEnvironmentFixesItsModeAndClient() {
        let environment = ComputerUseHelperV2.environment(mode: .bounded, client: Self.client)
        #expect(environment["CMUX_COMPUTER_USE_MODE"] == "bounded")
        #expect(environment["CMUX_COMPUTER_USE_CLIENT"] == Self.client)
    }
}
