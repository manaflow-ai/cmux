import CmuxCore
import Foundation
import Testing
@testable import CmuxRemoteWorkspace

@Suite("Bundled SSH daemon assets")
struct RemoteDaemonBundledAssetsTests {
    // Python zlib.compressobj(wbits: -15), independent of Foundation's encoder.
    private let compressedFixture = Data(base64Encoded: "S84trdAtSS0uAQA=")!
    private let binaryFixture = Data("cmux-test".utf8)

    private func makeEntry(os: String = "linux", arch: String = "amd64", checksum: String? = nil) throws -> WorkspaceRemoteDaemonManifest.Entry {
        let data = try JSONSerialization.data(withJSONObject: [
            "goOS": os,
            "goArch": arch,
            "assetName": "cmuxd-remote-\(os)-\(arch)-12301",
            "downloadURL": "http://127.0.0.1:1/unpublished",
            "sha256": checksum ?? "e180eb2dc2a6aba2143c10755a5ec12d5bb9a6e14bfec2326d4b6d1933e4c0b4"
        ])
        return try JSONDecoder().decode(WorkspaceRemoteDaemonManifest.Entry.self, from: data)
    }

    private func temporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cmux-bundled-daemon-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test("an unpublished app installs matching bytes without a network download", arguments: [
        ("darwin", "arm64"), ("darwin", "amd64"), ("linux", "arm64"), ("linux", "amd64")
    ])
    func installsWithoutPublication(os: String, arch: String) throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let entry = try makeEntry(os: os, arch: arch)
        try compressedFixture.write(to: root.appendingPathComponent(entry.assetName + ".deflate"))
        let repository = RemoteDaemonManifestRepository(homeDirectory: root, bundledAssetsDirectory: root)
        let download = try repository.downloadBinary(entry: entry, version: "test-nightly.12301")
        #expect(try Data(contentsOf: download.binaryURL) == binaryFixture)
        #expect(FileManager.default.isExecutableFile(atPath: download.binaryURL.path))
        #expect(!download.usedLiveManifestChecksumFallback)
        #expect(try repository.validatedCachedBinary(entry: entry, version: "test-nightly.12301") == download.binaryURL)
        // A second workspace may reach installation after another filled the cache.
        #expect(try repository.downloadBinary(entry: entry, version: "test-nightly.12301").binaryURL == download.binaryURL)
    }

    @Test("a corrupt or missing bundled binary cannot bypass checksum verification", arguments: ["checksum", "deflate", "missing"])
    func rejectsCorruptResource(failure: String) throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let entry = try makeEntry(checksum: failure == "checksum" ? String(repeating: "0", count: 64) : nil)
        if failure != "missing" {
            let content = failure == "deflate" ? Data([0xff, 0xff]) : compressedFixture
            try content.write(to: root.appendingPathComponent(entry.assetName + ".deflate"))
        }
        let repository = RemoteDaemonManifestRepository(homeDirectory: root, bundledAssetsDirectory: root)
        #expect(throws: (any Error).self) {
            try repository.downloadBinary(entry: entry, version: "test-nightly.12301")
        }
        let cache = try repository.cachedBinaryURL(version: "test-nightly.12301", goOS: entry.goOS, goArch: entry.goArch)
        #expect(!FileManager.default.fileExists(atPath: cache.path))
    }
}
