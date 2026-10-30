import Foundation
import Testing
@testable import CmuxNextCloud

// Each case owns a private broker process and pipe. Serializing the suite
// avoids exhausting the platform's concurrent process/pipe reader budget when
// the parameterized interruption matrix grows.
@Suite("Cloud Codex broker", .serialized, .timeLimit(.minutes(1)))
struct CloudCodexBrokerTests {
    actor Recorder {
        var files: [String: Data] = [:]
        var committed: (String, String, String, String)?
        var commitCount = 0
        var commitWaiter: (Int, CheckedContinuation<Void, Never>)?
        func awaitCount(_ count: Int) async {
            if commitCount >= count { return }
            await withCheckedContinuation { commitWaiter = (count, $0) }
        }
        var removals = 0
        var liveChecks = 0
        func liveUntilDelivery() -> Bool { liveChecks += 1; return liveChecks == 1 }
        var refuseRestore = false
        func failRestore(_ fail: Bool) { refuseRestore = fail }
        var refuseCommit = false
        func failCommit(_ fail: Bool) { refuseCommit = fail }
        var refuseDirectory = false
        func failDirectory(_ fail: Bool) { refuseDirectory = fail }
        func restore(_ path: String, _ data: Data) throws {
            if refuseRestore, path == CloudCodexBroker.modePath { throw Failure.denied }
            files[path] = data
        }
        var refuseRemoval = false
        var refuseAccessRead = false
        var heldRenewal = false
        func holdFirstRenewal() -> Bool {
            guard commitCount > 0, !heldRenewal else { return false }
            heldRenewal = true; return true
        }
        enum Failure: Error { case denied }
        func failRemoval(_ fail: Bool) { refuseRemoval = fail }
        func failAccessRead(_ fail: Bool) { refuseAccessRead = fail }
        func remove(_ path: String) throws {
            removals += 1
            if refuseRemoval { throw Failure.denied }
            files.removeValue(forKey: path)
        }

        func read(_ path: String) -> Data? { files[path] }
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
        /// The work that would pause here ended first (``passed()``): `entered()` returns rather
        /// than wait for a pause that never comes, and the test's own expectations fail instead.
        var over = false
        func pause() async {
            await withCheckedContinuation { continuation in
                waiting = continuation
                observer?.resume(); observer = nil
            }
        }
        func entered() async {
            if waiting != nil || over { return }
            await withCheckedContinuation { observer = $0 }
        }
        func passed() { over = true; observer?.resume(); observer = nil }
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
    if [ "$count" = 2 ]; then expiry=1; fi
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
        }, makeDirectory: { _ in }, readFile: { await recorder.read($0) },
                                      writeFile: { path, data, _ in
                                          if path.contains(".access-"), await recorder.holdFirstRenewal() { await gate.pause() }
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
        }, makeDirectory: { _ in }, readFile: { await recorder.read($0) }, writeFile: { path, data, _ in
            if path.contains(".access-"), await recorder.holdFirstRenewal() { await gate.pause() }
            await recorder.write(path, data)
        }, commitFiles: { a, b, c, d in await recorder.commit((a, b, c, d)) }, removeFile: { path in try await recorder.remove(path) })
        _ = try await broker.transfer(target: target, confirmed: true)
        await gate.entered()
        let other = CloudCodexBrokerTarget(machineID: "foreground-vm", capability: {
            .init(ownerVM: true, protocolVersion: 1, codexExternalAccessToken: true)
        }, makeDirectory: { _ in }, readFile: { _ in nil }, writeFile: { _, _, _ in }, commitFiles: { _, _, _, _ in }, removeFile: { _ in })
        _ = try await broker.transfer(target: other, confirmed: true, forceRefresh: true)
        await gate.open()
        await recorder.awaitCount(2)
        #expect(await broker.registeredMachineIDs() == Set([target.machineID, other.machineID]))
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

    @Test(arguments: [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13]) func deliversAccessOnlyGrantAndRestoresPriorModeOnRevoke(interruption: Int) async throws {
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
        await recorder.write(CloudCodexBroker.modePath, Data("team\n".utf8))
        let target = CloudCodexBrokerTarget(machineID: "vm-1", capability: {
            .init(ownerVM: true, protocolVersion: 1, codexExternalAccessToken: true)
        }, makeDirectory: { _ in
            if await recorder.refuseDirectory { throw Recorder.Failure.denied }
        }, readFile: { path in
            if await recorder.refuseAccessRead, path == CloudCodexBroker.accessPath { throw Recorder.Failure.denied }
            return await recorder.read(path)
        }, writeFile: { path, data, _ in try await recorder.restore(path, data) }, commitFiles: { a, b, c, d in
            if interruption == 3 { throw CloudCodexBrokerError.remoteDeliveryFailed }
            if await recorder.refuseCommit { throw CloudCodexBrokerError.remoteDeliveryFailed }
            if interruption == 1 || interruption == 2 { await gate.pause() }
            await recorder.commit((a, b, c, d))
            if interruption == 5 { throw CloudCodexBrokerError.remoteDeliveryFailed }
            if interruption == 11 { await recorder.failAccessRead(true); throw CloudCodexBrokerError.remoteDeliveryFailed }
            if interruption == 7 { await recorder.failRestore(true); await account.logout() }
            if interruption == 10 { await recorder.failRemoval(true) }
        }, removeFile: { path in try await recorder.remove(path) }, isLive: {
            if interruption == 4 { return await recorder.liveUntilDelivery() }
            return true
        })
        if interruption == 8 {
            await recorder.failCommit(true)
            await #expect(throws: CloudCodexBrokerError.remoteDeliveryFailed) { try await broker.transfer(target: target, confirmed: true) }
            try await broker.revoke(target: target)
            #expect(await recorder.read(CloudCodexBroker.accessPath) == nil)
            let changedMode = Data("own\n".utf8)
            await recorder.write(CloudCodexBroker.modePath, changedMode)
            await recorder.failCommit(false)
            _ = try await broker.transfer(target: target, confirmed: true)
            try await broker.revoke(target: target)
            #expect(await recorder.read(CloudCodexBroker.accessPath) == nil)
            #expect(await recorder.read(CloudCodexBroker.modePath) == changedMode)
            return
        }
        if interruption == 9 {
            await recorder.failCommit(true)
            await recorder.failAccessRead(true)
            await #expect(throws: CloudCodexBrokerError.remoteDeliveryFailed) { try await broker.transfer(target: target, confirmed: true) }
            #expect(await recorder.files.keys.filter { $0.contains(".access-") }.isEmpty)
            await recorder.failAccessRead(false)
            try await broker.revoke(target: target)
            return
        }
        if interruption == 10 {
            await #expect(throws: CloudCodexBrokerError.remoteDeliveryFailed) { try await broker.transfer(target: target, confirmed: true) }
            #expect(await recorder.files.keys.contains { $0.contains(".access-") })
            await #expect(throws: Recorder.Failure.denied) { try await broker.revoke(target: target) }
            #expect(await recorder.files.keys.contains { $0.contains(".access-") })
            await recorder.failRemoval(false)
            try await broker.revoke(target: target)
            #expect(await recorder.files.keys.filter { $0.contains(".access-") || $0.contains(".codex-") }.isEmpty)
            return
        }
        if interruption == 12 {
            await recorder.failCommit(true)
            await recorder.failRemoval(true)
            for _ in 0 ..< 2 {
                await #expect(throws: CloudCodexBrokerError.remoteDeliveryFailed) { try await broker.transfer(target: target, confirmed: true) }
            }
            let staged = await recorder.files.keys.filter { $0.contains(".access-") || $0.contains(".codex-") }
            #expect(staged.count == 4)
            await recorder.failRemoval(false)
            try await broker.revoke(target: target)
            #expect(await recorder.files.keys.filter { $0.contains(".access-") || $0.contains(".codex-") }.isEmpty)
            return
        }
        if interruption == 13 {
            await recorder.failCommit(true)
            await recorder.failRemoval(true)
            await #expect(throws: CloudCodexBrokerError.remoteDeliveryFailed) { try await broker.transfer(target: target, confirmed: true) }
            #expect(await recorder.files.keys.filter { $0.contains(".access-") || $0.contains(".codex-") }.count == 2)
            await recorder.failCommit(false)
            await recorder.failDirectory(true)
            await #expect(throws: CloudCodexBrokerError.remoteDeliveryFailed) { try await broker.transfer(target: target, confirmed: true) }
            await recorder.failDirectory(false)
            await recorder.failRemoval(false)
            try await broker.revoke(target: target)
            #expect(await recorder.files.keys.filter { $0.contains(".access-") || $0.contains(".codex-") }.isEmpty)
            return
        }
        if interruption == 11 {
            await #expect(throws: CloudCodexBrokerError.remoteDeliveryFailed) { try await broker.transfer(target: target, confirmed: true) }
            await recorder.failAccessRead(false)
            try await broker.revoke(target: target)
            #expect(await recorder.read(CloudCodexBroker.accessPath) == nil)
            #expect(await recorder.read(CloudCodexBroker.modePath) == Data("team\n".utf8))
            return
        }
        if interruption == 4 {
            await #expect(throws: CloudCodexBrokerError.targetOffline) { try await broker.transfer(target: target, confirmed: true) }
            #expect(await recorder.removals == 0)
            return
        }
        if interruption == 7 {
            await #expect(throws: CloudCodexBrokerError.remoteDeliveryFailed) { try await broker.transfer(target: target, confirmed: true) }
            #expect(await recorder.read(CloudCodexBroker.accessPath) == nil)
            #expect(await recorder.read(CloudCodexBroker.modePath) == Data("own\n".utf8))
            await recorder.failRestore(false)
            try await broker.revoke(target: target)
            #expect(await recorder.read(CloudCodexBroker.modePath) == Data("team\n".utf8))
            return
        }
        if interruption == 5 {
            await #expect(throws: CloudCodexBrokerError.remoteDeliveryFailed) { try await broker.transfer(target: target, confirmed: true) }
            #expect(await recorder.read(CloudCodexBroker.accessPath) == nil)
            #expect(await recorder.read(CloudCodexBroker.modePath) == Data("team\n".utf8))
            return
        }
        if interruption == 3 {
            await recorder.write(CloudCodexBroker.accessPath, Data("existing-grant".utf8))
            await #expect(throws: CloudCodexBrokerError.remoteDeliveryFailed) { try await broker.transfer(target: target, confirmed: true) }
            #expect(await recorder.files[CloudCodexBroker.accessPath] == Data("existing-grant".utf8))
            return
        }
        let transfer = Task { try await broker.transfer(target: target, confirmed: true) }
        if interruption == 1 || interruption == 2 {
            // A transfer that fails before its commit (say the broker never answers) ends the wait
            // for the pause, so this case fails on its expectations instead of hanging the run.
            let ended = Task { _ = try? await transfer.value; await gate.passed() }
            defer { ended.cancel() }
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
        if interruption == 6 {
            await recorder.write(CloudCodexBroker.modePath, Data("team\n".utf8))
            try await broker.revoke(target: target)
            #expect(await recorder.read(CloudCodexBroker.modePath) == Data("team\n".utf8))
            return
        }
        await recorder.failRemoval(true)
        await #expect(throws: Recorder.Failure.denied) { try await broker.revoke(target: target) }
        #expect(await recorder.files[CloudCodexBroker.accessPath] != nil)
        await #expect(throws: CloudCodexBrokerError.cancelled) { try await broker.transfer(target: target, confirmed: true) }
        #expect(!(await broker.registeredMachineIDs()).contains(target.machineID))
        await recorder.failRemoval(false)
        await recorder.failRestore(true)
        await #expect(throws: Recorder.Failure.denied) { try await broker.revoke(target: target) }
        #expect(await recorder.files[CloudCodexBroker.accessPath] == nil)
        await recorder.failRestore(false)
        try await broker.revoke(target: target)
        #expect(await recorder.files[CloudCodexBroker.accessPath] == nil)
        #expect(await recorder.files.count == 1)
        #expect(await recorder.files[CloudCodexBroker.modePath] == Data("team\n".utf8))
    }

    @Test(arguments: [false, true]) func abandonedLoginPreservesExistingMode(cancel: Bool) async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let fake = root.appendingPathComponent("broker.sh")
        try #"""
#!/bin/sh
while IFS= read -r line; do
  id=$(printf '%s' "$line" | sed -E 's/.*"id":([0-9]+).*/\1/')
  echo "{\"id\":$id,\"error\":\"codex_auth_unavailable\"}"
done
"""#.write(to: fake, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fake.path)
        let recorder = Recorder()
        let scope = CloudCodexBrokerScope(userID: "user", teamID: nil)
        let broker = CloudCodexBroker(scope: scope, currentScope: { scope }, executable: fake,
                                      codexExecutable: URL(fileURLWithPath: "/bin/false"), home: root.appendingPathComponent("holder"))
        await recorder.write(CloudCodexBroker.modePath, Data("team\n".utf8))
        let target = CloudCodexBrokerTarget(machineID: "vm", capability: {
            .init(ownerVM: true, protocolVersion: 1, codexExternalAccessToken: true)
        }, makeDirectory: { _ in }, readFile: { await recorder.read($0) }, writeFile: { _, _, _ in }, commitFiles: { _, _, _, _ in }, removeFile: { try await recorder.remove($0) })
        await #expect(throws: CloudCodexBrokerError.notAuthenticated) { try await broker.transfer(target: target, confirmed: true) }
        let pending = Task { try await broker.waitForLoginAndTransfer(target: target, confirmed: true, timeout: cancel ? .seconds(300) : .zero) }
        if cancel { pending.cancel() }
        await #expect(throws: (any Error).self) { try await pending.value }
        #expect(await broker.registeredMachineIDs().isEmpty)
        #expect(await recorder.removals == 0)
        #expect(await recorder.read(CloudCodexBroker.modePath) == Data("team\n".utf8))
    }

    /// A session reads its holder's reply while another reader in the process waits on a quiet
    /// pipe. Foundation reads every `FileHandle.bytes` one at a time, so when the session read
    /// with `bytes`, another session's idle reader (any idle `bytes` reader) left this reply
    /// unread: the request failed at its 15 s bound as brokerUnavailable, and
    /// deliversAccessOnlyGrantAndRestoresPriorModeOnRevoke(interruption:) waited forever for a
    /// commit (feat-cmux-next swift test, 2026-10-28).
    @Test func aSessionReadsItsReplyWhileAnotherReaderWaits() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let fake = root.appendingPathComponent("broker.sh")
        try #"""
#!/bin/sh
while IFS= read -r line; do
  id=$(printf '%s' "$line" | sed -E 's/.*"id":([0-9]+).*/\1/')
  echo "{\"id\":$id,\"result\":{\"accessToken\":\"access\",\"chatgptAccountId\":\"acct-1\",\"expiresAt\":2147483647}}"
done
"""#.write(to: fake, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fake.path)
        // Another reader in the process, waiting on a pipe that goes quiet after one byte. It
        // says when it has that byte; its next step is the read that waits, which it starts
        // before the session below has even launched its holder.
        let quiet = Pipe()
        let (reading, started) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let waiting = Task.detached {
            for try await _ in quiet.fileHandleForReading.bytes { started.yield() }
        }
        defer { try? quiet.fileHandleForWriting.close(); waiting.cancel() }
        try quiet.fileHandleForWriting.write(contentsOf: Data([0x2E]))
        for await _ in reading { break }
        let session = try CodexBrokerSession(executable: fake, executablePrefix: [], codexExecutable: URL(fileURLWithPath: "/bin/false"),
                                             home: root.appendingPathComponent("holder"))
        let reply = try await withThrowingTaskGroup(of: BrokerResult?.self) { group in
            group.addTask { try await session.request(method: "access") }
            group.addTask {
                try await Task.sleep(for: .seconds(10))
                return nil
            }
            defer { group.cancelAll() }
            return try await group.next() ?? nil
        }
        #expect(reply?.chatgptAccountID == "acct-1", "the holder's reply was not read within 10 s")
        await session.shutdown()
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("cmux-codex-broker-test-\(UUID().uuidString)")
    }
}
