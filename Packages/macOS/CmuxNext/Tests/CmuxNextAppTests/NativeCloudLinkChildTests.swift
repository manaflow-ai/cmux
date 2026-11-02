import CmuxNextDaemon
import CryptoKit
import Foundation
import Testing
@testable import CmuxNextCloud

@Suite struct NativeCloudLinkChildTests {
    private actor Calls {
        var count = 0
        func answer(_ bytes: Data) throws -> Data {
            let request = try NativeCloudBrokerRequest(bytes)
            count += 1
            return try JSONSerialization.data(withJSONObject: ["version": 1, "id": request.id, "error": ["code": "cloud.machine.not_found"]])
        }
    }

    private func bundle(root: URL) async throws -> URL {
        let source = try #require(SameTreeDaemonBinary.url, "the hosted lane must provide its matching CLI")
        let bundle = root.appendingPathComponent("Fixture.app"), contents = bundle.appendingPathComponent("Contents")
        let bin = contents.appendingPathComponent("Resources/bin"), mac = contents.appendingPathComponent("MacOS")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: mac, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: source, to: bin.appendingPathComponent("cmux-tui"))
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: mac.appendingPathComponent("Fixture"))
        let info = ["CFBundleExecutable": "Fixture", "CFBundleIdentifier": "com.cmuxterm.tests.native-broker", "CFBundlePackageType": "APPL", "CFBundleVersion": "1"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: contents.appendingPathComponent("Info.plist"))
        let signed = try await ProcessRunner.run(executable: URL(fileURLWithPath: "/usr/bin/codesign"),
            arguments: ["--force", "--sign", "-", "--timestamp=none", bundle.path], environment: [:], timeout: .seconds(30), clock: ContinuousClock())
        #expect(signed.status == 0)
        return bundle
    }

    private func startup(recheck: @escaping @Sendable () async throws -> Void = {}) throws -> NativeCloudLinkStartup {
        let key = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: Data(repeating: 7, count: 32))
        let mesh = "mesh_" + String(repeating: "0", count: 26), device = "dev_" + String(repeating: "0", count: 26)
        let bytes = try JSONSerialization.data(withJSONObject: ["version": 2, "install": "inst_native",
            "team": "team_" + String(repeating: "a", count: 20), "mesh": mesh,
            "tenant": "tenant_a", "ipv4_cidr": "10.128.0.0/20", "device": device,
            "tunnel": ["id": "tun_" + String(repeating: "0", count: 26), "meshId": mesh, "deviceId": device,
                "endpointHost": "203.0.113.30", "endpointPort": 51820, "serverPublicKey": Data(repeating: 3, count: 32).base64EncodedString(),
                "interfaceAddress": "100.64.0.1/32", "meshAddress": "10.128.0.10", "allowedIps": ["10.128.0.0/20"],
                "mtu": 1280, "persistentKeepaliveSeconds": 25],
            "private_key": key.rawRepresentation.base64EncodedString()])
        return NativeCloudLinkStartup(bytes: bytes, publicKey: key.publicKey.rawRepresentation.base64EncodedString(), recheck: recheck)
    }

    @Test func ownedBundledChildReceivesItsKeyAndServesTheRealCLI() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let bundle = try await bundle(root: root), startup = try startup(), calls = Calls()
        let state = root.appendingPathComponent("native")
        let child = NativeCloudLinkChild(bundleURL: bundle, publisher: .development, directory: state, home: root, prepare: { startup }, reply: { try await calls.answer($0) })
        do {
            let socket = try await child.socketPath()
            let answer = try await ProcessRunner.run(executable: bundle.appendingPathComponent("Contents/Resources/bin/cmux-tui"),
                arguments: ["link", "dial", "--host", "host_11111111111111111111", "--service", "ssh", "--socket", socket],
                environment: ["HOME": root.path], timeout: .seconds(10), clock: ContinuousClock())
            #expect(answer.status == 2)
            let error = try #require(JSONSerialization.jsonObject(with: answer.stderr) as? [String: Any])
            #expect(error["error_code"] as? String == "unknown_host")
            #expect(await calls.count == 1)
            #expect(!FileManager.default.fileExists(atPath: state.appendingPathComponent("private.key").path))
            #expect(!String(reflecting: startup).contains(Data(repeating: 7, count: 32).base64EncodedString()))
            await child.stop()
        } catch { await child.stop(); throw error }
    }

    @Test func anEndedScopeNeverDeliversTheStartupKey() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let bundle = try await bundle(root: root), startup = try startup { throw CancellationError() }, calls = Calls()
        let state = root.appendingPathComponent("native")
        let child = NativeCloudLinkChild(bundleURL: bundle, publisher: .development, directory: state, home: root, prepare: { startup }, reply: { try await calls.answer($0) })
        await #expect(throws: CancellationError.self) { try await child.socketPath() }
        await child.stop()
        #expect(!FileManager.default.fileExists(atPath: state.path))
        #expect(await calls.count == 0)
    }

    @Test func anExecutableSymlinkOutsideTheBundleCannotReceiveAKey() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let bundle = try await bundle(root: root), startup = try startup(), calls = Calls()
        let binary = bundle.appendingPathComponent("Contents/Resources/bin/cmux-tui")
        try FileManager.default.removeItem(at: binary)
        try FileManager.default.createSymbolicLink(at: binary, withDestinationURL: #require(SameTreeDaemonBinary.url))
        let child = NativeCloudLinkChild(bundleURL: bundle, publisher: .development, directory: root.appendingPathComponent("native"), home: root, prepare: { startup }, reply: { try await calls.answer($0) })
        await #expect(throws: (any Error).self) { try await child.socketPath() }
        await child.stop()
        #expect(await calls.count == 0)
    }
}
