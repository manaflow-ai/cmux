import Foundation
import Testing
@testable import CmuxNextApp

@Suite("Cloud Codex broker")
struct CloudCodexBrokerTests {
    actor Recorder {
        var files: [String: Data] = [:]
        var committed: (String, String, String, String)?
        var commitCount = 0

        func write(_ path: String, _ data: Data) { files[path] = data }
        func commit(_ paths: (String, String, String, String)) {
            commitCount += 1
            committed = paths
            if let data = files[paths.0] { files[paths.1] = data }
            if let data = files[paths.2] { files[paths.3] = data }
        }
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

    @Test func scheduledRenewalFansOutToRegisteredTargets() async throws {
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
    count=$((count + 1)); expiry=$(($(date +%s) + 65))
    if [ "$count" -gt 1 ]; then expiry=2147483647; fi
    echo "{\"id\":$id,\"result\":{\"accessToken\":\"access-$count\",\"chatgptAccountId\":\"acct-1\",\"expiresAt\":$expiry}}"
  fi
done
"""#.write(to: fake, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fake.path)
        let recorder = Recorder()
        let scope = CloudCodexBrokerScope(userID: "user-1", teamID: nil)
        let broker = CloudCodexBroker(scope: scope, currentScope: { scope }, executable: fake,
                                      codexExecutable: URL(fileURLWithPath: "/bin/false"), home: root.appendingPathComponent("holder"))
        let target = CloudCodexBrokerTarget(machineID: "vm-renew", capability: {
            .init(ownerVM: true, protocolVersion: 1, codexExternalAccessToken: true)
        }, makeDirectory: { _ in }, readFile: { _ in nil },
                                      writeFile: { path, data, _ in await recorder.write(path, data) },
                                      commitFiles: { a, b, c, d in await recorder.commit((a, b, c, d)) },
                                      removeFile: { _ in })
        _ = try await broker.transfer(target: target, confirmed: true)
        try await Task.sleep(for: .seconds(3))
        #expect(await recorder.commitCount >= 2)
    }

    @Test func deliversAccessOnlyGrantAndRestoresPriorModeOnRevoke() async throws {
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
        let broker = CloudCodexBroker(scope: scope, currentScope: { scope }, executable: fake,
                                      codexExecutable: URL(fileURLWithPath: "/bin/false"), home: root.appendingPathComponent("holder"))
        let target = CloudCodexBrokerTarget(machineID: "vm-1", capability: {
            .init(ownerVM: true, protocolVersion: 1, codexExternalAccessToken: true)
        }, makeDirectory: { _ in }, readFile: { _ in Data("team\n".utf8) }, writeFile: { path, data, _ in await recorder.write(path, data) }, commitFiles: { a, b, c, d in await recorder.commit((a, b, c, d)) }, removeFile: { _ in })

        let grant = try await broker.transfer(target: target, confirmed: true)
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

        try await broker.revoke(target: target)
        #expect(await recorder.files[CloudCodexBroker.modePath] == Data("team\n".utf8))
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("cmux-codex-broker-test-\(UUID().uuidString)")
    }
}
