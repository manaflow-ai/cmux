import Foundation
import Testing
@testable import CmuxLiveCode

/// A patch's sidecar (`NAME.json`, scripts/live-code/patch.py) names what it was built from, so the
/// engine reuses the image it already loaded for the same code instead of loading one more.
struct LivePatchSidecarTests {
    private func folder() throws -> LiveFolder {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("live-code-sidecar-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return LiveFolder(url: url)
    }

    @Test func theSidecarCarriesTheSourceKey() throws {
        let live = try folder()
        defer { try? FileManager.default.removeItem(at: live.url) }
        try Data(#"{"commit": "abc+dirty", "files": ["A.swift"], "source": "5e1f"}"#.utf8)
            .write(to: live.url.appendingPathComponent("patch-1.json"))
        let sidecar = try #require(live.sidecar("patch-1.dylib"))
        #expect(sidecar.source == "5e1f")
        #expect(sidecar.commit == "abc+dirty")
    }

    @Test func anOlderSidecarHasNoKeySoItsPatchLoadsAnImageOfItsOwn() throws {
        let live = try folder()
        defer { try? FileManager.default.removeItem(at: live.url) }
        try Data(#"{"commit": null, "files": []}"#.utf8).write(to: live.url.appendingPathComponent("patch-2.json"))
        #expect(try #require(live.sidecar("patch-2.dylib")).source == nil)
    }
}
