import Foundation
import Testing
@testable import CmuxNextCloud

@Suite("Cloud Codex broker", .timeLimit(.minutes(1)))
struct CloudCodexBrokerTests {
    @Test func readsPrettyPrintedRunningDaemonCapabilities() {
        let output = "{\n  \"capabilities\": [\n    \"codex-external-access-v1\"\n  ]\n}"
        #expect(CloudCodexBrokerTarget.supportsExternalAccess(output))
        #expect(!CloudCodexBrokerTarget.supportsExternalAccess("{\"capabilities\":[]}"))
    }

    actor Recorder {
        var files: [String: Data] = [:]
        var committed: (String, String, String, String)?
        var commitCount = 0
        var commitWaiter: (Int, CheckedContinuation<Void, Never>)?
        func awaitCount(_ count: Int) async {
            if commitCount >= count { return }
            await withCheckedContinuation { commitWaiter = (count, $0) }
        }
        var refuseRemoval = false
        enum Failure: Error { case denied }
        func failRemoval(_ fail: Bool) { refuseRemoval = fail }
        func remove(_ path: String) throws {
            if refuseRemoval { throw Failure.denied }
            files.removeValue(forKey: path)
        }

        func write(_ path: String, _ data: Data) { files[path] = data }
        func commit(_ paths: (String, String, String, String)) {
            commitCount += 1
            if let waiter = commitWaiter, commitCount >= waiter.0 {
                commitWaiter = nil; waiter.1.resume()
            }
            committed = paths
            if let data = files[paths.0] { files[paths.1] = data }
            if let data = files[paths.2] { files[paths.3] = data }
        }
    }

    actor Gate {
        var waiting: CheckedContinuation<Void, Never>?
        var observer: CheckedContinuation<Void, Never>?
        func pause() async {
            await withCheckedContinuation { continuation in
                waiting = continuation
                observer?.resume(); observer = nil
            }
        }
        func entered() async {
            if waiting != nil { return }
            await withCheckedContinuation { observer = $0 }
        }
        func open() { waiting?.resume(); waiting = nil }
    }

    @Test func revocationFencesPendingValidation() async throws {
        let gate = Gate()
        let scope = CloudCodexBrokerScope(userID: "user-1", teamID: nil)
        let broker = CloudCodexBroker(scope: scope, currentScope: { scope }, executable: URL(fileURLWithPath: "/bin/false"), codexExecutable: URL(fileURLWithPath: "/bin/false"), home: temporaryDirectory())
        let target = CloudCodexBrokerTarget(machineID: "vm-1", capability: {
            await gate.pause()
            return .init(ownerVM: true, protocolVersion: 1, codexExternalAccessToken: true)
        }, makeDirectory: { _ in }, readFile: { _ in nil }, writeFile: { _, _, _ in }, commitFiles: { _, _, _, _ in }, removeFile: { _ in })
        let pending = Task { try await broker.transfer(target: target, confirmed: true) }
        await gate.entered()
        try await broker.revoke(target: target)
        await gate.open()
        await #expect(throws: CloudCodexBrokerError.cancelled) { try await pending.value }
    }

    @Test func requiresExplicitConsentAndOwnerCapability() async throws {
        let scope = CloudCodexBrokerScope(userID: "user-1", teamID: "team-1")
        let broker = CloudCodexBroker(scope: scope, currentScope: { scope }, executable: URL(fileURLWithPath: "/bin/false"), codexExecutable: URL(fileURLWithPath: "/bin/false"), home: temporaryDirectory())
        let target = CloudCodexBrokerTarget(machineID: "vm-1", capability: {
            .init(ownerVM: false, protocolVersion: 1, codexExternalAccessToken: true)
        }, makeDirectory: { _ in }, readFile: { _ in nil }, writeFile: { _, _, _ in }, commitFiles: { _, _, _, _ in }, removeFile: { _ in })

        await #expect(throws: CloudCodexBrokerError.consentRequired) {
            try await broker.transfer(target: target, confirmed: false)
        }
        await #expect(throws: CloudCodexBrokerError.sharedMachine) {
            try await broker.transfer(target: target, confirmed: true)
        }
    }

    @Test func scheduledRenewalSurvivesConcurrentTargetRevocation() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let fake = root.appendingPathComponent("broker.sh")
        try #"""
#!/bin/sh
count=0
while IFS= read -r line; do
  id=$(printf '%s' "$line" | sed -E 's/.*"id":([0-9]+).*/\1/')
  if printf '%s' "$line" | grep -q '"method":"access"'; then
    count=$((count + 1)); expiry=$(($(date +%s) + 123))
    if [ "$count" -gt 1 ]; then expiry=2147483647; fi
    echo "{\"id\":$id,\"result\":{\"accessToken\":\"access-$count\",\"chatgptAccountId\":\"acct-1\",\"expiresAt\":$expiry}}"
  fi
done
"""#.write(to: fake, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fake.path)
        let recorder = Recorder()
        let gate = Gate()
        let scope = CloudCodexBrokerScope(userID: "user-1", teamID: nil)
        let broker = CloudCodexBroker(scope: scope, currentScope: { scope }, executable: fake,
                                      codexExecutable: URL(fileURLWithPath: "/bin/false"), home: root.appendingPathComponent("holder"))
        let target = CloudCodexBrokerTarget(machineID: "vm-renew", capability: {
            .init(ownerVM: true, protocolVersion: 1, codexExternalAccessToken: true)
        }, makeDirectory: { _ in }, readFile: { _ in nil },
                                      writeFile: { path, data, _ in
                                          if path.contains(".access-"), await recorder.commitCount > 0 { await gate.pause() }
                                          await recorder.write(path, data)
                                      },
                                      commitFiles: { a, b, c, d in await recorder.commit((a, b, c, d)) },
                                      removeFile: { path in try await recorder.remove(path) })
        _ = try await broker.transfer(target: target, confirmed: true)
        let second = Recorder()
        let target2 = CloudCodexBrokerTarget(machineID: "vm-renew-2", capability: {
            .init(ownerVM: true, protocolVersion: 1, codexExternalAccessToken: true)
        }, makeDirectory: { _ in }, readFile: { _ in nil },
                                            writeFile: { path, data, _ in await second.write(path, data) },
                                            commitFiles: { a, b, c, d in await second.commit((a, b, c, d)) }, removeFile: { path in try await second.remove(path) })
        _ = try await broker.transfer(target: target2, confirmed: true)
        await gate.entered()
        let revocation = Task { try await broker.revoke(target: target) }
        while await broker.registeredMachineIDs().contains(target.machineID) { await Task.yield() }
        await gate.open()
        try await revocation.value
        await second.awaitCount(2)
        #expect(await second.commitCount >= 2)
    }

    @Test func foregroundRefreshDoesNotCancelActiveRenewalDelivery() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let fake = root.appendingPathComponent("broker.sh")
        try #"""
#!/bin/sh
count=0
while IFS= read -r line; do
  id=$(printf '%s' "$line" | sed -E 's/.*"id":([0-9]+).*/\1/')
  if printf '%s' "$line" | grep -q '"method":"access"'; then
    count=$((count + 1)); expiry=$(($(date +%s) + 123))
    if [ "$count" -gt 1 ]; then expiry=2147483647; fi
    echo "{\"id\":$id,\"result\":{\"accessToken\":\"access-$count\",\"chatgptAccountId\":\"acct-1\",\"expiresAt\":$expiry}}"
  fi
done
"""#.write(to: fake, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fake.path)
        let recorder = Recorder()
        let gate = Gate()
        let scope = CloudCodexBrokerScope(userID: "user-1", teamID: nil)
        let broker = CloudCodexBroker(scope: scope, currentScope: { scope }, executable: fake,
                                      codexExecutable: URL(fileURLWithPath: "/bin/false"), home: root.appendingPathComponent("holder"))
        let target = CloudCodexBrokerTarget(machineID: "vm-refresh", capability: {
            .init(ownerVM: true, protocolVersion: 1, codexExternalAccessToken: true)
        }, makeDirectory: { _ in }, readFile: { _ in nil }, writeFile: { path, data, _ in
            if path.contains(".access-"), await recorder.commitCount > 0 { await gate.pause() }
            await recorder.write(path, data)
        }, commitFiles: { a, b, c, d in await recorder.commit((a, b, c, d)) }, removeFile: { path in try await recorder.remove(path) })
        _ = try await broker.transfer(target: target, confirmed: true)
        await gate.entered()
        let foreground = Task { try await broker.transfer(target: target, confirmed: true, forceRefresh: true) }
        await Task.yield()
        await gate.open()
        _ = try await foreground.value
        #expect(await broker.registeredMachineIDs() == Set([target.machineID]))
        #expect(await recorder.files[CloudCodexBroker.accessPath] != nil)
    }

    @Test func retriesWithANewSessionAfterHolderExit() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let fake = root.appendingPathComponent("broker.sh")
        try #"""
#!/bin/sh
if [ ! -f "$3/started" ]; then touch "$3/started"; read -r ignored; exit 1; fi
while IFS= read -r line; do
  id=$(printf '%s' "$line" | sed -E 's/.*"id":([0-9]+).*/\1/')
  echo "{\"id\":$id,\"result\":{\"accessToken\":\"access\",\"chatgptAccountId\":\"acct-1\",\"expiresAt\":2147483647}}"
done
"""#.write(to: fake, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fake.path)
        let scope = CloudCodexBrokerScope(userID: "user-1", teamID: nil)
        let broker = CloudCodexBroker(scope: scope, currentScope: { scope }, executable: fake,
                                      codexExecutable: URL(fileURLWithPath: "/bin/false"), home: root.appendingPathComponent("holder"))
        let target = CloudCodexBrokerTarget(machineID: "vm-1", capability: {
            .init(ownerVM: true, protocolVersion: 1, codexExternalAccessToken: true)
        }, makeDirectory: { _ in }, readFile: { _ in nil }, writeFile: { _, _, _ in }, commitFiles: { _, _, _, _ in }, removeFile: { _ in })
        await #expect(throws: (any Error).self) { try await broker.transfer(target: target, confirmed: true) }
        let grant = try await broker.transfer(target: target, confirmed: true)
        #expect(grant.chatgptAccountID == "acct-1")
    }

    actor Account {
        var scope: CloudCodexBrokerScope?
        init(_ scope: CloudCodexBrokerScope) { self.scope = scope }
        func logout() { scope = nil }
    }

    @Test(arguments: [0, 1, 2]) func deliversAccessOnlyGrantAndRestoresPriorModeOnRevoke(interruption: Int) async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let fake = root.appendingPathComponent("broker.sh")
        try #"""
#!/bin/sh
while IFS= read -r line; do
  id=$(printf '%s' "$line" | sed -E 's/.*"id":([0-9]+).*/\1/')
  if printf '%s' "$line" | grep -q '"method":"access"'; then
    echo "{\"id\":$id,\"result\":{\"accessToken\":\"access-token\",\"chatgptAccountId\":\"acct-1\",\"expiresAt\":2147483647}}"
  elif printf '%s' "$line" | grep -q '"method":"login"'; then
    echo "{\"id\":$id,\"result\":{\"verificationUrl\":\"https://auth.openai.com/codex/device\",\"userCode\":\"ABCD-EFGH\"}}"
  else
    echo "{\"id\":$id,\"result\":{}}"
  fi
done
"""#.write(to: fake, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fake.path)

        let recorder = Recorder()
        let scope = CloudCodexBrokerScope(userID: "user-1", teamID: "team-1")
        let account = Account(scope)
        let gate = Gate()
        let broker = CloudCodexBroker(scope: scope, currentScope: { await account.scope }, executable: fake,
                                      codexExecutable: URL(fileURLWithPath: "/bin/false"), home: root.appendingPathComponent("holder"))
        let target = CloudCodexBrokerTarget(machineID: "vm-1", capability: {
            .init(ownerVM: true, protocolVersion: 1, codexExternalAccessToken: true)
        }, makeDirectory: { _ in }, readFile: { _ in Data("team\n".utf8) }, writeFile: { path, data, _ in await recorder.write(path, data) }, commitFiles: { a, b, c, d in
            if interruption > 0 { await gate.pause() }
            await recorder.commit((a, b, c, d))
        }, removeFile: { path in try await recorder.remove(path) })
        let transfer = Task { try await broker.transfer(target: target, confirmed: true) }
        if interruption > 0 {
            await gate.entered()
            if interruption == 1 { await account.logout() } else { transfer.cancel() }
            await gate.open()
            await #expect(throws: interruption == 1 ? CloudCodexBrokerError.scopeChanged : .cancelled) { try await transfer.value }
            #expect(await recorder.files[CloudCodexBroker.accessPath] == nil)
            #expect(await recorder.files[CloudCodexBroker.modePath] == Data("team\n".utf8))
            #expect(await broker.registeredMachineIDs().isEmpty)
            return
        }
        let grant = try await transfer.value
        #expect(grant.chatgptAccountID == "acct-1")
        let paths = await recorder.committed
        #expect(paths?.1 == CloudCodexBroker.accessPath)
        #expect(paths?.3 == CloudCodexBroker.modePath)
        let access = await recorder.files[CloudCodexBroker.accessPath]
        let object = try #require(access.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] })
        #expect(object["schema"] as? Int == 1)
        #expect(object["bridge"] as? String == "codex-external-access-v1")
        #expect(object["accessToken"] as? String == "access-token")
        #expect(await recorder.files[CloudCodexBroker.modePath] == Data("own\n".utf8))

        let recorder2 = Recorder()
        let target2 = CloudCodexBrokerTarget(machineID: "vm-2", capability: {
            .init(ownerVM: true, protocolVersion: 1, codexExternalAccessToken: true)
        }, makeDirectory: { _ in }, readFile: { _ in nil }, writeFile: { path, data, _ in await recorder2.write(path, data) }, commitFiles: { a, b, c, d in await recorder2.commit((a, b, c, d)) }, removeFile: { _ in })
        _ = try await broker.transfer(target: target2, confirmed: true)
        #expect(await recorder2.files[CloudCodexBroker.accessPath] != nil)
        #expect(await recorder2.files[CloudCodexBroker.modePath] == Data("own\n".utf8))

        #expect(await recorder.files.count == 2)
        await recorder.failRemoval(true)
        await #expect(throws: Recorder.Failure.denied) { try await broker.revoke(target: target) }
        #expect(await recorder.files[CloudCodexBroker.accessPath] != nil)
        await recorder.failRemoval(false)
        try await broker.revoke(target: target)
        #expect(await recorder.files[CloudCodexBroker.accessPath] == nil)
        #expect(await recorder.files.count == 1)
        #expect(await recorder.files[CloudCodexBroker.modePath] == Data("team\n".utf8))
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("cmux-codex-broker-test-\(UUID().uuidString)")
    }
}
