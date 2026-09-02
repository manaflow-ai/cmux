import Foundation
import Testing
@testable import CmuxNestedTopology

@Suite struct RemoteHerdrSizeAuthorityTests {
    private func store(env: [String: String] = [:]) throws -> (RemoteHerdrSizeAuthorityStore, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("herdr-size-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let xdg = root.appendingPathComponent("xdg")
        let native = root.appendingPathComponent("native")
        try FileManager.default.createDirectory(at: xdg, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: native, withIntermediateDirectories: true)
        let store = RemoteHerdrSizeAuthorityStore(
            directories: [
                xdg.appendingPathComponent("cmux-herdr"),
                native,
            ],
            environment: env
        )
        return (store, root)
    }

    @Test func claimNativeBlocksPluginPaneIds() throws {
        let (store, _) = try store()
        let written = store.claimNative(fingerprint: "fp")
        #expect(!written.isEmpty)
        #expect(store.read(fingerprint: "fp") == RemoteHerdrSizeAuthority.nativeToken)
        #expect(store.mayClaim(paneID: "native", fingerprint: "fp"))
        #expect(!store.mayClaim(paneID: "w1:p1", fingerprint: "fp"))
        #expect(!store.mayClaim(paneID: "w1:p2", fingerprint: "fp"))
    }

    @Test func envOverrideBeatsFile() throws {
        let (store, _) = try store(env: ["CMUX_HERDR_SIZE_AUTHORITY": "w2:p9"])
        _ = store.claimNative(fingerprint: "fp")
        #expect(store.read(fingerprint: "fp") == "w2:p9")
        #expect(store.mayClaim(paneID: "w2:p9", fingerprint: "fp"))
        #expect(!store.mayClaim(paneID: "native", fingerprint: "fp"))
    }

    @Test func clearRemovesElection() throws {
        let (store, _) = try store()
        _ = store.claimNative(fingerprint: "fp")
        store.clear(fingerprint: "fp")
        #expect(store.read(fingerprint: "fp") == nil)
        #expect(store.mayClaim(paneID: "w1:p1", fingerprint: "fp"))
    }

    @Test func pluginFormatLineIsReadable() throws {
        let (store, _) = try store()
        let path = store.directories[0].appendingPathComponent("size-authority-fp")
        try FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "w2:p1\n".write(to: path, atomically: true, encoding: .utf8)
        #expect(store.read(fingerprint: "fp") == "w2:p1")
        #expect(store.mayClaim(paneID: "w2:p1", fingerprint: "fp"))
        #expect(!store.mayClaim(paneID: "w2:p2", fingerprint: "fp"))
    }
}
