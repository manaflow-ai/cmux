import Foundation
import Testing
@testable import CmuxCore

@Suite("WorkspaceRemoteDaemonManifest decoding")
struct WorkspaceRemoteDaemonManifestTests {
    private let manifestJSON = """
    {
      "schemaVersion": 1,
      "appVersion": "0.20.0",
      "releaseTag": "cmuxd-remote-v0.20.0",
      "releaseURL": "https://github.com/manaflow-ai/cmux/releases/tag/cmuxd-remote-v0.20.0",
      "checksumsAssetName": "checksums.txt",
      "checksumsURL": "https://example.invalid/checksums.txt",
      "entries": [
        {
          "goOS": "linux",
          "goArch": "amd64",
          "assetName": "cmuxd-remote-linux-amd64",
          "downloadURL": "https://example.invalid/cmuxd-remote-linux-amd64",
          "sha256": "abc123"
        },
        {
          "goOS": "darwin",
          "goArch": "arm64",
          "assetName": "cmuxd-remote-darwin-arm64",
          "downloadURL": "https://example.invalid/cmuxd-remote-darwin-arm64",
          "sha256": "def456"
        }
      ]
    }
    """

    @Test("decodes the embedded manifest JSON shape")
    func decodesManifest() throws {
        let manifest = try JSONDecoder().decode(
            WorkspaceRemoteDaemonManifest.self,
            from: Data(manifestJSON.utf8)
        )
        #expect(manifest.schemaVersion == 1)
        #expect(manifest.appVersion == "0.20.0")
        #expect(manifest.entries.count == 2)
    }

    @Test("entry lookup matches on the exact GOOS/GOARCH pair")
    func entryLookup() throws {
        let manifest = try JSONDecoder().decode(
            WorkspaceRemoteDaemonManifest.self,
            from: Data(manifestJSON.utf8)
        )
        #expect(manifest.entry(goOS: "linux", goArch: "amd64")?.sha256 == "abc123")
        #expect(manifest.entry(goOS: "darwin", goArch: "arm64")?.assetName == "cmuxd-remote-darwin-arm64")
        #expect(manifest.entry(goOS: "linux", goArch: "arm64") == nil)
    }

    @Test("decodes from an Info dictionary under the wire-pinned key")
    func decodesFromInfoDictionary() throws {
        let manifest = try #require(WorkspaceRemoteDaemonManifest(infoDictionary: [
            WorkspaceRemoteDaemonManifest.infoDictionaryKey: manifestJSON,
        ]))
        #expect(WorkspaceRemoteDaemonManifest.infoDictionaryKey == "CMUXRemoteDaemonManifestJSON")
        #expect(manifest.releaseTag == "cmuxd-remote-v0.20.0")
        #expect(manifest.entry(goOS: "linux", goArch: "amd64")?.assetName == "cmuxd-remote-linux-amd64")
    }

    @Test("Info-dictionary decode rejects a missing, blank, or undecodable manifest")
    func infoDictionaryDecodeRejectsInvalid() {
        #expect(WorkspaceRemoteDaemonManifest(infoDictionary: nil) == nil)
        #expect(WorkspaceRemoteDaemonManifest(infoDictionary: [:]) == nil)
        #expect(WorkspaceRemoteDaemonManifest(infoDictionary: [
            WorkspaceRemoteDaemonManifest.infoDictionaryKey: "   \n ",
        ]) == nil)
        #expect(WorkspaceRemoteDaemonManifest(infoDictionary: [
            WorkspaceRemoteDaemonManifest.infoDictionaryKey: "{not json",
        ]) == nil)
    }
}

@Suite("WorkspaceRemoteWebSocketDaemonEndpoint")
struct WorkspaceRemoteWebSocketDaemonEndpointTests {
    @Test("proxy broker key component trims and binds url, session, and expiry")
    func proxyBrokerKeyComponent() {
        let endpoint = WorkspaceRemoteWebSocketDaemonEndpoint(
            url: " wss://broker.example/ws ",
            headers: ["Authorization": "Bearer x"],
            token: "secret",
            sessionId: " session-1 ",
            expiresAtUnix: 1234
        )
        #expect(
            endpoint.proxyBrokerKeyComponent
                == "wss://broker.example/ws\u{1f}session-1\u{1f}1234"
        )

        let other = WorkspaceRemoteWebSocketDaemonEndpoint(
            url: "wss://broker.example/ws",
            headers: [:],
            token: "secret",
            sessionId: "session-2",
            expiresAtUnix: 1234
        )
        #expect(endpoint.proxyBrokerKeyComponent != other.proxyBrokerKeyComponent)
    }
}
