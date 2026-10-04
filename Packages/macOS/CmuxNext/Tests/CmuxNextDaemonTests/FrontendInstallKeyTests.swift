import Foundation
import Synchronization
import Testing
@testable import CmuxNextDaemon

/// P8 slice 3b-2: the app's install key, its storage, the launcher hand-off
/// and the `client-hello` lines of the handshake.
@Suite(.timeLimit(.minutes(1))) struct FrontendInstallKeyTests {
    static let key = FrontendInstallKey(installID: "inst_test-01", key: Data(0..<32))!

    /// The same vector the daemon tests (cmux-local-auth
    /// frontend_proof_tests.rs `VECTOR`).
    @Test func proofMatchesTheDaemonVector() {
        #expect(Self.key.proof(nonce: Data(repeating: 0xa5, count: 32))
            == "1878e5949b7e511bb06b3f98939beabd11626e5519834bb0fa371420cecb6793")
        #expect(Self.key.proof(nonceHex: String(repeating: "a5", count: 32))
            == Self.key.proof(nonce: Data(repeating: 0xa5, count: 32)))
        #expect(Self.key.proof(nonceHex: "a5") == nil)
        #expect(Self.key.proof(nonceHex: String(repeating: "zz", count: 32)) == nil)
    }

    @Test func payloadRoundTripsAndTheKeyNeverPrints() {
        #expect(String(decoding: Self.key.payload, as: UTF8.self)
            == "cmuxik1 inst_test-01 000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f\n")
        #expect(FrontendInstallKey(payload: Self.key.payload) == Self.key)
        #expect(!"\(Self.key)".contains("0001020304") && !String(reflecting: Self.key).contains("0001020304"))
        let generated = FrontendInstallKey.generate()
        #expect(generated.installID.hasPrefix("inst_") && generated != FrontendInstallKey.generate())
        for bad in ["", "a b", "a/b", String(repeating: "a", count: 129)] {
            #expect(FrontendInstallKey(installID: bad, key: Data(0..<32)) == nil)
        }
        #expect(FrontendInstallKey(installID: "inst_a", key: Data(count: 32)) == nil)
        #expect(FrontendInstallKey(payload: Data("cmuxik1 inst_a 0011\n".utf8)) == nil)
    }

    @Test func fileStoreCreatesOneOwnerOnlyKeyAndRefusesAWiderFile() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("fik-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = FileFrontendInstallKeyStore(file: dir.appendingPathComponent("frontend-install-key"))
        let first = try #require(store.loadOrCreate())
        #expect(store.loadOrCreate() == first)
        let mode = try FileManager.default.attributesOfItem(atPath: store.file.path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
        // A group-readable key file is not trusted (and not replaced).
        try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: store.file.path)
        #expect(store.loadOrCreate() == nil)
    }

    @Test func ensureSendsTheKeyOnStdinOnly() async throws {
        var configuration = DaemonLauncher.Configuration(binary: URL(fileURLWithPath: "/bin/cat"), session: "s")
        #expect(!DaemonLauncher.ensureArguments(configuration).contains("--install-key-stdin"))
        configuration.installKey = Self.key
        let arguments = DaemonLauncher.ensureArguments(configuration)
        #expect(arguments.contains("--install-key-stdin"))
        #expect(!arguments.joined(separator: " ").contains("inst_test-01"))
        // ProcessRunner hands stdin through a pipe the child reads to EOF.
        let result = try await ProcessRunner.run(executable: URL(fileURLWithPath: "/bin/cat"), arguments: [],
                                                 environment: [:], stdin: Self.key.payload,
                                                 timeout: .seconds(10), clock: ContinuousClock())
        #expect(result.status == 0 && result.stdout == Self.key.payload)
    }

    /// The handshake sends `client-hello` step 1 right after `identify`
    /// and the proof as the very next line, before `set-client-info`.
    @Test func handshakeProvesTheKeyRightAfterStepOne() async throws {
        let seen = Mutex<[[String: JSONValue]]>([])
        let nonce = String(repeating: "a5", count: 32)
        let server = try FakeDaemonServer(handler: ConnectionTests.handshake { request, id in
            seen.withLock { $0.append(request) }
            guard request["cmd"]?.stringValue == "client-hello" else { return [] }
            if request["proof"] == nil {
                return [#"{"id":\#(id),"ok":true,"data":{"connection_id":"7","nonce":"\#(nonce)"}}"#]
            }
            return [#"{"id":\#(id),"ok":true,"data":{"verified":true,"install_id":"inst_test-01","connection_id":"7"}}"#]
        })
        defer { server.stop() }
        let connection = DaemonConnection(endpoint: DaemonEndpoint(socketPath: server.path),
                                          configuration: .init(clientHello: ClientHelloIdentity(installKey: Self.key)))
        try await connection.start()
        await connection.close()
        let hellos = seen.withLock { $0 }
        #expect(hellos.count == 2)
        #expect(hellos[0]["role"]?.stringValue == "main" && hellos[0]["install_id"]?.stringValue == "inst_test-01")
        #expect(hellos[1]["proof"]?.stringValue == Self.key.proof(nonce: Data(repeating: 0xa5, count: 32)))
    }

    /// An older daemon answers `client-hello` with an error: the connection
    /// still starts (unverified), and no proof is sent.
    @Test func anOlderDaemonOnlyLeavesTheConnectionUnverified() async throws {
        let proofs = Mutex(0)
        let server = try FakeDaemonServer(handler: ConnectionTests.handshake { request, id in
            guard request["cmd"]?.stringValue == "client-hello" else { return [] }
            if request["proof"] != nil { proofs.withLock { $0 += 1 } }
            return [#"{"id":\#(id),"ok":false,"error":"unknown command"}"#]
        })
        defer { server.stop() }
        let connection = DaemonConnection(endpoint: DaemonEndpoint(socketPath: server.path),
                                          configuration: .init(clientHello: ClientHelloIdentity(installKey: Self.key)))
        try await connection.start()
        await connection.close()
        #expect(proofs.withLock { $0 } == 0)
    }
}

/// Coordinator conditions for the DEV key file (2026-10-04).
@Suite struct FrontendInstallKeyStoreChoiceTests {
    /// A signed build (a Team ID) uses the Keychain, never the DEV file,
    /// even when a key file sits in its state directory.
    @Test func aSignedBuildNeverUsesTheDevFile() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("fik-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = FileFrontendInstallKeyStore(file: dir.appendingPathComponent("frontend-install-key")).loadOrCreate()
        let signed = FrontendInstallKeyStores.forApp(session: "cmux-app-t", stateDirectory: dir,
                                                     bundleID: "com.cmuxterm.app.debug.t", team: "ABCDE12345")
        #expect(signed is KeychainFrontendInstallKeyStore)
        #expect((signed as? KeychainFrontendInstallKeyStore)?.account == "cmux-app-t")
        let unsigned = FrontendInstallKeyStores.forApp(session: "cmux-app-t", stateDirectory: dir,
                                                       bundleID: nil, team: nil)
        #expect((unsigned as? FileFrontendInstallKeyStore)?.file == dir.appendingPathComponent("frontend-install-key"))
        // No tag state directory: an unsigned build has no key at all.
        #expect(FrontendInstallKeyStores.forApp(session: "cmux-app", stateDirectory: nil, bundleID: nil, team: nil) == nil)
    }

    /// The file is created 0600 in one step (no chmod after) and is refused
    /// when its mode or its owner is wrong.
    @Test func theDevFileIsRefusedWithAWrongModeOrOwner() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("fik-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("frontend-install-key")
        let previous = umask(0)
        defer { umask(previous) }
        let created = try #require(FileFrontendInstallKeyStore(file: file).loadOrCreate())
        let mode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
        #expect(FileFrontendInstallKeyStore(file: file).loadOrCreate() == created)
        // Another owner: refused, and the file is not replaced.
        #expect(FileFrontendInstallKeyStore(file: file, owner: geteuid() + 1).loadOrCreate() == nil)
        for wider in [0o604, 0o620, 0o700] {
            try FileManager.default.setAttributes([.posixPermissions: wider], ofItemAtPath: file.path)
            #expect(FileFrontendInstallKeyStore(file: file).loadOrCreate() == nil, "mode \(String(wider, radix: 8))")
        }
    }
}
