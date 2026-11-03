import Foundation
import Testing
@testable import CmuxNextCloud

/// A renewal that fails while the network is away (the Mac woke from sleep at the renewal, before its
/// Wi-Fi was back) tries again later instead of ending renewal for good: the Cloud machine's Codex keeps
/// its access once the network returns.
@Suite("Cloud Codex broker renewal retry", .serialized, .timeLimit(.minutes(1)))
struct CloudCodexBrokerRenewalRetryTests {
    actor Files {
        var files: [String: Data] = [:]
        var commits = 0
        var waiter: (Int, CheckedContinuation<Void, Never>)?
        func write(_ path: String, _ data: Data) { files[path] = data }
        func read(_ path: String) -> Data? { files[path] }
        func remove(_ path: String) { files.removeValue(forKey: path) }
        func commit(_ paths: (String, String, String, String)) {
            commits += 1
            if let data = files[paths.0] { files[paths.1] = data }
            if let data = files[paths.2] { files[paths.3] = data }
            if let waiter, commits >= waiter.0 { self.waiter = nil; waiter.1.resume() }
        }
        func awaitCommits(_ count: Int) async {
            if commits >= count { return }
            await withCheckedContinuation { waiter = (count, $0) }
        }
    }

    /// The holder fails the four tries of the first renewal (the old code's whole budget) and answers
    /// again after: a later renewal delivers new access to the machine. `exit`: the holder dies; else it
    /// answers `codex_auth_unavailable`, as the real holder does when Codex's refresh fails offline.
    @Test(arguments: [true, false]) func aRenewalThatFailsWhileOfflineTriesAgainLater(exit: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("broker-retry-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let counter = root.appendingPathComponent("count")
        let fake = root.appendingPathComponent("broker.sh")
        // Each access request counts in a file (a failed holder is started again, its count kept). The
        // first answers with a grant that expires at once; the next four fail as an offline holder does
        // (it dies, or answers codex_auth_unavailable); the sixth answers with a long grant.
        try #"""
#!/bin/sh
counter="\#(counter.path)"
while IFS= read -r line; do
  id=$(printf '%s' "$line" | sed -E 's/.*"id":([0-9]+).*/\1/')
  if printf '%s' "$line" | grep -q '"method":"access"'; then
    count=$(( $(cat "$counter" 2>/dev/null || echo 0) + 1 )); echo "$count" > "$counter"
    if [ "$count" -ge 2 ] && [ "$count" -le 5 ]; then
      if [ "\#(exit ? "exit" : "answer")" = exit ]; then exit 1; fi
      echo "{\"id\":$id,\"error\":\"codex_auth_unavailable\"}"; continue
    fi
    expiry=$(($(date +%s) + 121)); if [ "$count" -gt 1 ]; then expiry=2147483647; fi
    echo "{\"id\":$id,\"result\":{\"accessToken\":\"access-$count\",\"chatgptAccountId\":\"acct-1\",\"expiresAt\":$expiry}}"
  fi
done
"""#.write(to: fake, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fake.path)
        let files = Files()
        let scope = CloudCodexBrokerScope(userID: "user-1", teamID: nil)
        let broker = CloudCodexBroker(scope: scope, currentScope: { scope }, executable: fake,
                                      codexExecutable: URL(fileURLWithPath: "/bin/false"), home: root.appendingPathComponent("holder"),
                                      renewalRetryBase: .milliseconds(200))
        let target = CloudCodexBrokerTarget(machineID: "vm-retry", capability: {
            .init(ownerVM: true, protocolVersion: 1, codexExternalAccessToken: true)
        }, makeDirectory: { _ in }, readFile: { await files.read($0) }, writeFile: { path, data, _ in await files.write(path, data) },
                                            commitFiles: { a, b, c, d in await files.commit((a, b, c, d)) }, removeFile: { await files.remove($0) })
        _ = try await broker.transfer(target: target, confirmed: true)
        await files.awaitCommits(2)
        let delivered = try #require(await files.read(CloudCodexBroker.accessPath))
        #expect(String(decoding: delivered, as: UTF8.self).contains("access-6"), "the renewal after the outage did not deliver new access")
        _ = await broker.shutdown()
    }

    /// The holder refreshes fine but the machine's VM API is away for the renewal's delivery tries: the next
    /// renewal comes after the backoff, not at the refreshed grant's expiry, and delivers (cmux#33387).
    @Test func aDeliveryThatFailsAfterAGoodRefreshTriesAgainLater() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("broker-delivery-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let fake = root.appendingPathComponent("broker.sh")
        // Every access answers; the first grant expires at once, the rest are long.
        try #"""
#!/bin/sh
count=0
while IFS= read -r line; do
  id=$(printf '%s' "$line" | sed -E 's/.*"id":([0-9]+).*/\1/')
  if printf '%s' "$line" | grep -q '"method":"access"'; then
    count=$((count + 1)); expiry=$(($(date +%s) + 121)); if [ "$count" -gt 1 ]; then expiry=2147483647; fi
    echo "{\"id\":$id,\"result\":{\"accessToken\":\"access-$count\",\"chatgptAccountId\":\"acct-1\",\"expiresAt\":$expiry}}"
  fi
done
"""#.write(to: fake, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fake.path)
        let files = Files()
        let away = Away(failures: 4)
        let scope = CloudCodexBrokerScope(userID: "user-1", teamID: nil)
        let broker = CloudCodexBroker(scope: scope, currentScope: { scope }, executable: fake,
                                      codexExecutable: URL(fileURLWithPath: "/bin/false"), home: root.appendingPathComponent("holder"),
                                      renewalRetryBase: .milliseconds(200))
        let target = CloudCodexBrokerTarget(machineID: "vm-away", capability: {
            .init(ownerVM: true, protocolVersion: 1, codexExternalAccessToken: true)
        }, makeDirectory: { _ in }, readFile: { await files.read($0) }, writeFile: { path, data, _ in await files.write(path, data) },
                                            commitFiles: { a, b, c, d in
                                                if await files.commits > 0, await away.fails() { throw CloudCodexBrokerError.remoteDeliveryFailed }
                                                await files.commit((a, b, c, d))
                                            }, removeFile: { await files.remove($0) })
        _ = try await broker.transfer(target: target, confirmed: true)
        await files.awaitCommits(2)
        #expect(await away.left == 0)
        let delivered = try #require(await files.read(CloudCodexBroker.accessPath))
        #expect(!String(decoding: delivered, as: UTF8.self).contains("access-1\""), "the machine kept its first, expired access")
        _ = await broker.shutdown()
    }

    /// A holder whose every access answers a long grant, a broker on it with a short backoff, and a
    /// machine taken back after a relaunch: it holds this holder's access from the last run, expiring
    /// `leftExpiresIn` seconds from now, and its VM API refuses the next `refusals` commits.
    private func relaunchFixture(leftExpiresIn: TimeInterval, refusals: Int) async throws
        -> (root: URL, broker: CloudCodexBroker, other: CloudCodexBrokerTarget, taken: CloudCodexBrokerTarget, files: Files, away: Away) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("broker-catchup-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let fake = root.appendingPathComponent("broker.sh")
        try #"""
#!/bin/sh
count=0
while IFS= read -r line; do
  id=$(printf '%s' "$line" | sed -E 's/.*"id":([0-9]+).*/\1/')
  if printf '%s' "$line" | grep -q '"method":"access"'; then
    count=$((count + 1))
    echo "{\"id\":$id,\"result\":{\"accessToken\":\"access-$count\",\"chatgptAccountId\":\"acct-1\",\"expiresAt\":2147483647}}"
  fi
done
"""#.write(to: fake, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fake.path)
        let home = root.appendingPathComponent("holder")
        let holder = CloudCodexDeliveryRecord(home: home).holderID()
        let scope = CloudCodexBrokerScope(userID: "user-1", teamID: nil)
        let broker = CloudCodexBroker(scope: scope, currentScope: { scope }, executable: fake,
                                      codexExecutable: URL(fileURLWithPath: "/bin/false"), home: home,
                                      renewalRetryBase: .milliseconds(200))
        let otherFiles = Files()
        let other = CloudCodexBrokerTarget(machineID: "vm-other", capability: {
            .init(ownerVM: true, protocolVersion: 1, codexExternalAccessToken: true)
        }, makeDirectory: { _ in }, readFile: { await otherFiles.read($0) }, writeFile: { path, data, _ in await otherFiles.write(path, data) },
                                           commitFiles: { a, b, c, d in await otherFiles.commit((a, b, c, d)) }, removeFile: { await otherFiles.remove($0) })
        let files = Files()
        let left: [String: Any] = ["schema": 1, "bridge": "codex-external-access-v1", "accessToken": "left-access",
                                   "chatgptAccountId": "acct-1", "holder": holder, "previousMode": NSNull(),
                                   "expiresAt": Int64(Date().addingTimeInterval(leftExpiresIn).timeIntervalSince1970)]
        await files.write(CloudCodexBroker.accessPath, try JSONSerialization.data(withJSONObject: left))
        await files.write(CloudCodexBroker.modePath, Data("own\n".utf8))
        let away = Away(failures: refusals)
        let taken = CloudCodexBrokerTarget(machineID: "vm-taken", capability: {
            .init(ownerVM: true, protocolVersion: 1, codexExternalAccessToken: true)
        }, makeDirectory: { _ in }, readFile: { await files.read($0) }, writeFile: { path, data, _ in await files.write(path, data) },
                                           commitFiles: { a, b, c, d in
                                               if await away.fails() { throw CloudCodexBrokerError.remoteDeliveryFailed }
                                               await files.commit((a, b, c, d))
                                           }, removeFile: { await files.remove($0) })
        return (root, broker, other, taken, files, away)
    }

    /// cmux#34010: a machine taken back after a relaunch whose access ends before the scheduled renewal
    /// gets new access at once; when that delivery fails it tries again, before the access ends, instead of
    /// waiting for the scheduled renewal (here, years out) while the machine's Codex loses its access.
    @Test func aFailedCatchUpAfterARelaunchTriesAgainBeforeTheAccessEnds() async throws {
        let (root, broker, other, taken, files, away) = try await relaunchFixture(leftExpiresIn: 600, refusals: 2)
        defer { try? FileManager.default.removeItem(at: root) }
        // This run already renews for another machine, with a grant that lasts.
        _ = try await broker.transfer(target: other, confirmed: true)
        await broker.resume(target: taken, erase: false)
        #expect(await broker.registeredMachineIDs() == ["vm-other", "vm-taken"])
        await files.awaitCommits(1)
        #expect(await away.left == 0)
        let delivered = try #require(await files.read(CloudCodexBroker.accessPath))
        #expect(!String(decoding: delivered, as: UTF8.self).contains("left-access"), "the machine kept the access it was left")
        _ = await broker.shutdown()
    }

    /// cmux#34010: the catch-up retry ends when the machine's access does, and a sign-out (the machine's
    /// erase) or a delete cancels it at once.
    @Test func theCatchUpRetryStopsAtTheExpiryAndOnEraseOrDelete() async throws {
        let (root, broker, other, taken, _, _) = try await relaunchFixture(leftExpiresIn: 2, refusals: .max)
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try await broker.transfer(target: other, confirmed: true)
        await broker.resume(target: taken, erase: false)
        let retry = try #require(await broker.catchUpTask("vm-taken"))
        await retry.value
        #expect(await broker.catchUpMachineIDs().isEmpty)
        // The machine stays registered: the scheduled renewal still reaches it.
        #expect(await broker.registeredMachineIDs().contains("vm-taken"))

        let (root2, broker2, other2, taken2, _, _) = try await relaunchFixture(leftExpiresIn: 600, refusals: .max)
        defer { try? FileManager.default.removeItem(at: root2) }
        _ = try await broker2.transfer(target: other2, confirmed: true)
        await broker2.resume(target: taken2, erase: false)
        let erased = try #require(await broker2.catchUpTask("vm-taken"))
        try await broker2.revoke(target: taken2)
        #expect(erased.isCancelled)
        #expect(await broker2.catchUpMachineIDs().isEmpty)
        _ = await broker2.shutdown()
        _ = await broker.shutdown()

        let (root3, broker3, other3, taken3, _, _) = try await relaunchFixture(leftExpiresIn: 600, refusals: .max)
        defer { try? FileManager.default.removeItem(at: root3) }
        _ = try await broker3.transfer(target: other3, confirmed: true)
        await broker3.resume(target: taken3, erase: false)
        let deleted = try #require(await broker3.catchUpTask("vm-taken"))
        await broker3.discardDeletedTarget("vm-taken")
        #expect(deleted.isCancelled)
        #expect(await broker3.catchUpMachineIDs().isEmpty)
        _ = await broker3.shutdown()
    }

    /// The VM API refuses the next `failures` deliveries.
    actor Away {
        var left: Int
        init(failures: Int) { left = failures }
        func fails() -> Bool {
            guard left > 0 else { return false }
            left -= 1
            return true
        }
    }

    /// The backoff doubles from its base and stops at the cap.
    @Test func theBackoffDoublesUpToItsCap() async {
        let scope = CloudCodexBrokerScope(userID: "user-1", teamID: nil)
        let broker = CloudCodexBroker(scope: scope, currentScope: { scope }, executable: URL(fileURLWithPath: "/bin/false"),
                                      codexExecutable: URL(fileURLWithPath: "/bin/false"), home: FileManager.default.temporaryDirectory)
        #expect(CloudCodexBroker.retriesLater(CloudCodexBrokerError.notAuthenticated))
        #expect(!CloudCodexBroker.retriesLater(CloudCodexBrokerError.accountChanged))
        #expect(await broker.renewalRetryDelay(1) == .seconds(15))
        #expect(await broker.renewalRetryDelay(2) == .seconds(30))
        #expect(await broker.renewalRetryDelay(9) == CloudCodexBroker.renewalRetryCap)
        #expect(CloudCodexBroker.retriesLater(CloudCodexBrokerError.brokerUnavailable))
        #expect(!CloudCodexBroker.retriesLater(CloudCodexBrokerError.scopeChanged))
        #expect(!CloudCodexBroker.retriesLater(CloudCodexBrokerError.cancelled))
    }
}
