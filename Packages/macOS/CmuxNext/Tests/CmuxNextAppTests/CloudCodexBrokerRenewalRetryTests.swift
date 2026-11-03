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
