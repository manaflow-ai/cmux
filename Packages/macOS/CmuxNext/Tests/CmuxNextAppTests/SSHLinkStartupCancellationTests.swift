import CmuxNextRemote
import Foundation
import Testing

@Suite struct SSHLinkStartupCancellationTests {
    @Test func stoppedStartupCannotPublishIntoReconnect() async throws {
        let environment = HeldEnvironment()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ssh-cancel-\(UUID().uuidString)")
        let link = SSHMachineLink(
            host: try SSHHost(destination: SSHDestination(parsing: "nohost.invalid")),
            binary: root.appendingPathComponent("missing-tui"), paths: SSHPaths(root: root),
            commandLine: SSHCommandLine(sshBinary: root.appendingPathComponent("missing-ssh").path),
            environment: { await environment.read() }, onStatus: { _ in })
        await link.handle(.connect)
        let oldAttempt = Task { try await link.socketPath() }
        await environment.waitForRead()
        await link.stop()
        await link.handle(.connect)
        await environment.release()
        do {
            _ = try await oldAttempt.value
            Issue.record("Stopped startup returned a socket")
        } catch is CancellationError {
            // Stop owns and cancels its startup, even while environment lookup is suspended.
        } catch {
            Issue.record("Stopped startup reported a stale failure: \(error)")
        }
        #expect(await link.status == .connecting, "Old startup must not publish recovery for the new connection")
        do {
            _ = try await link.socketPath()
            Issue.record("Missing ssh unexpectedly launched")
        } catch {
            #expect(await environment.readCount == 2, "Reconnect must start independent work")
            #expect(await link.status.needsRecovery, "The new attempt's own error must still be published")
        }
        await link.stop()
    }

    private actor HeldEnvironment {
        private var pending: CheckedContinuation<[String: String], Never>?
        private var started: CheckedContinuation<Void, Never>?
        private(set) var readCount = 0

        func read() async -> [String: String] {
            readCount += 1
            guard readCount == 1 else { return [:] }
            return await withCheckedContinuation { continuation in
                pending = continuation
                started?.resume()
                started = nil
            }
        }

        func waitForRead() async {
            if readCount > 0 { return }
            await withCheckedContinuation { started = $0 }
        }

        func release() {
            pending?.resume(returning: [:])
            pending = nil
        }
    }
}
