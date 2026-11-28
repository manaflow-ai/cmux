@testable import CmuxMobileSSH
import NIOSSH
import Foundation
import Testing

@Suite(.enabled(if: ProcessInfo.processInfo.environment["CMUX_SSH_LAB"] != nil))
struct SSHKeyInstallerLabTests {
    let lab = ProcessInfo.processInfo.environment["CMUX_SSH_LAB"] ?? ""

    @Test func appendIsIdempotentAndHandlesQuotes() async throws {
        let key = try SSHParsedPrivateKey(openSSH: try String(contentsOfFile: "\(lab)/client_ed25519", encoding: .utf8)).key
        let connection = try await SSHConnection.connect(
            to: SSHEndpoint(host: "127.0.0.1", port: 2222, username: NSUserName()),
            credentials: [.privateKey(key)],
            hostKeyVerifier: RecordingVerifier(accept: true)
        )
        let dir = "/tmp/cmux-install-\(UUID().uuidString)/.ssh"
        let line = "ssh-ed25519 AAAATEST it's-a-comment"
        try await SSHKeyInstaller(sshDirectory: dir).append(publicKeyLine: line, over: connection)
        try await SSHKeyInstaller(sshDirectory: dir).append(publicKeyLine: line, over: connection)
        let contents = try String(contentsOfFile: "\(dir)/authorized_keys", encoding: .utf8)
        #expect(contents == line + "\n")
        let mode = try FileManager.default.attributesOfItem(atPath: "\(dir)/authorized_keys")[.posixPermissions] as? Int
        #expect(mode == 0o600)
        await connection.close()
    }
}

struct SSHStoreTests {
    @Test func hostStoreRoundTripsAndPinsKeys() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cmux-hosts-\(UUID().uuidString)")
        let store = SSHHostStore(directory: dir)
        let jump = SSHHostRecord(name: "bastion", endpoint: SSHEndpoint(host: "b.example", username: "ops"))
        var host = SSHHostRecord(name: "prod", endpoint: SSHEndpoint(host: "p.example", port: 2200, username: "deploy"), jumpHostID: jump.id)
        try await store.upsert(jump)
        try await store.upsert(host)
        host.persistence = .tmux
        try await store.upsert(host)
        await store.pin(SSHHostKey(openSSHString: "ssh-ed25519 AAAA"), for: host.endpoint.hostKeyIdentity)

        let reloaded = SSHHostStore(directory: dir)
        #expect(await reloaded.all().map(\.name) == ["bastion", "prod"])
        #expect(await reloaded.host(id: host.id)?.persistence == .tmux)
        #expect(await reloaded.pinnedKey(for: "[p.example]:2200")?.openSSHString == "ssh-ed25519 AAAA")
        try await reloaded.delete(id: jump.id)
        #expect(await reloaded.host(id: host.id)?.jumpHostID == nil)
    }

    @Test func hostKeyVerdicts() {
        let a = SSHHostKey(openSSHString: "ssh-ed25519 AAAA")
        let b = SSHHostKey(openSSHString: "ssh-ed25519 BBBB")
        #expect(SSHHostKeyVerdict(presented: a, pinned: nil) == .unknown(presented: a))
        #expect(SSHHostKeyVerdict(presented: a, pinned: a) == .trusted)
        #expect(SSHHostKeyVerdict(presented: b, pinned: a) == .changed(pinned: a, presented: b))
    }

    @Test func keyStoreImportsAndLoadsFromKeychain() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cmux-keys-\(UUID().uuidString)")
        let path = dir.appendingPathComponent("k").path
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        _ = try shell("ssh-keygen -q -t ed25519 -N 'pw' -C lab -f \(path)")
        let store = SSHKeyStore(directory: dir, keychainService: "dev.cmux.ssh.tests.\(UUID().uuidString)")
        let record = try await store.importKey(label: "Laptop key", privateKeyText: try String(contentsOfFile: path, encoding: .utf8), passphrase: "pw")
        let pub = try shell("cut -d' ' -f1,2 \(path).pub")
        #expect(record.publicKeyLine == pub + " Laptop-key@cmux-ios")
        let loaded = try await store.privateKey(for: record.id)
        #expect(String(openSSHPublicKey: loaded.publicKey) == pub)
        try await store.delete(id: record.id)
        #expect(await store.all().isEmpty)
    }
}
