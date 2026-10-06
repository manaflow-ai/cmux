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

    /// A tag's first launch: its state directory does not exist yet when
    /// the launcher asks for the key (`server ensure` makes it later). The
    /// store still makes the key, in an owner-only directory, so the daemon
    /// this launch starts gets it and the app's connection is verified
    /// (nxdog46-v1: without it every verified-app feature, such as the
    /// clipboard-read broker, was refused until the next launch).
    @Test func aFreshTagsFirstLaunchStillGetsAKey() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("fik-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        let state = base.appendingPathComponent("tags/fresh/tui", isDirectory: true)
        let store = FileFrontendInstallKeyStore(file: state.appendingPathComponent("frontend-install-key"))
        let key = try #require(store.loadOrCreate(), "the first launch has a key")
        #expect(store.loadOrCreate() == key)
        let mode = try FileManager.default.attributesOfItem(atPath: state.path)[.posixPermissions] as? Int
        #expect(mode == 0o700, "the state directory is owner-only, as server ensure makes it")
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

/// `user_origin_allowed` in the `client-hello` replies: the connection
/// claims origin `user` only when the last hello reply allows it.
@Suite(.timeLimit(.minutes(1))) struct ClientHelloUserOriginTests {
    /// Starts a connection against a daemon whose step 1 answers `start`
    /// and step 2 answers `proved` (nil = an error line); returns
    /// `userOriginAllowed` after the handshake.
    static func allowed(installKey: FrontendInstallKey?, start: String, proved: String?) async throws -> Bool {
        let server = try FakeDaemonServer(handler: ConnectionTests.handshake { request, id in
            guard request["cmd"]?.stringValue == "client-hello" else { return [] }
            if request["proof"] == nil { return [#"{"id":\#(id),"ok":true,"data":\#(start)}"#] }
            guard let proved else { return [#"{"id":\#(id),"ok":false,"error":"client-hello refused","error_code":"client_hello.refused"}"#] }
            return [#"{"id":\#(id),"ok":true,"data":\#(proved)}"#]
        })
        defer { server.stop() }
        let connection = DaemonConnection(endpoint: DaemonEndpoint(socketPath: server.path),
                                          configuration: .init(clientHello: ClientHelloIdentity(installKey: installKey)))
        try await connection.start()
        let allowed = await connection.userOriginAllowed
        await connection.close()
        return allowed
    }

    static let nonce = String(repeating: "a5", count: 32)

    /// DEV build: step 1 is not yet proved; the step 2 value counts.
    @Test func theProofReplyDecides() async throws {
        let start = #"{"connection_id":"7","nonce":"\#(nonce)","user_origin_allowed":false}"#
        #expect(try await Self.allowed(installKey: FrontendInstallKeyTests.key, start: start,
                                       proved: #"{"verified":true,"install_id":"inst_test-01","connection_id":"7","user_origin_allowed":true}"#))
        #expect(try await !Self.allowed(installKey: FrontendInstallKeyTests.key, start: start, proved: nil))
    }

    /// Signed build: step 1 alone (no nonce, no proof) can allow it.
    @Test func aSignedStepOneDecides() async throws {
        #expect(try await Self.allowed(installKey: nil, start: #"{"connection_id":"7","user_origin_allowed":true}"#, proved: nil))
        #expect(try await !Self.allowed(installKey: nil, start: #"{"connection_id":"7","user_origin_allowed":false}"#, proved: nil))
    }

    /// An older daemon sends no field: origin `user` is not allowed.
    @Test func aMissingFieldIsFalse() async throws {
        #expect(try await !Self.allowed(installKey: nil, start: #"{"connection_id":"7"}"#, proved: nil))
        #expect(try await !Self.allowed(installKey: FrontendInstallKeyTests.key,
                                        start: #"{"connection_id":"7","nonce":"\#(nonce)"}"#,
                                        proved: #"{"verified":true,"install_id":"inst_test-01","connection_id":"7"}"#))
    }
}

/// Coordinator conditions for the DEV key file (2026-10-04).
@Suite struct FrontendInstallKeyStoreChoiceTests {
    /// A signed build (a Team ID) has no install key at all: the daemon
    /// accepts only the code signature there, so a key would grant nothing.
    /// It never uses the DEV file and creates no Keychain item, even when a
    /// key file sits in its state directory.
    @Test func aSignedBuildHasNoInstallKeyStore() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("fik-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = FileFrontendInstallKeyStore(file: dir.appendingPathComponent("frontend-install-key")).loadOrCreate()
        let signed = FrontendInstallKeyStores.forApp(stateDirectory: dir, team: "ABCDE12345")
        #expect(signed == nil)
        let unsigned = FrontendInstallKeyStores.forApp(stateDirectory: dir, team: nil)
        #expect((unsigned as? FileFrontendInstallKeyStore)?.file == dir.appendingPathComponent("frontend-install-key"))
        // No tag state directory: an unsigned build has no key at all.
        #expect(FrontendInstallKeyStores.forApp(stateDirectory: nil, team: nil) == nil)
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
