import Foundation
import Testing
@testable import CmuxNextDaemon

/// Icon assets (`icon-assets-v1`) against the pinned branch cmux-tui: what the icon picker's
/// Image and SVG tabs do (cx-qno.2.1). The daemon stores an SVG sanitized, a workspace takes its
/// icon value, and refuses an asset it never stored.
@Suite(.enabled(if: RealBinary.isBranchBuild, "needs the same-tree cmux-tui (scripts/cmux-next/pin-cmux-tui.sh fetch)"),
       .timeLimit(.minutes(2)), .liveDaemon)
struct BranchIconAssetTests {
    @Test func aStoredSVGBecomesAWorkspaceIcon() async throws {
        try await BranchDaemonHarness.with { h in
            let (key, _, _) = try await h.workspaceWithTerminal("assets")
            let svg = Data(#"<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16"><script>alert(1)</script><path d="M0 0h16v16H0z"/></svg>"#.utf8)
            let assets = IconAssetClient(h.connection)
            let stored = try await assets.put(mediaType: "image/svg+xml", data: svg)
            #expect(stored.icon.hasPrefix("svg:sha256-"))

            let blob = try await assets.get(stored.icon)
            #expect(blob.mediaType == "image/svg+xml")
            let text = String(decoding: blob.data, as: UTF8.self)
            #expect(!text.contains("script") && text.contains("<path"), "stored sanitized: \(text)")

            try await h.connection.setWorkspaceMetadata(key, icon: .set(stored.icon))
            try await h.store.waitUntil("store sees the svg icon") {
                h.store.workspaces.first { $0.key == key }?.icon == stored.icon
            }
            let missing = "svg:sha256-" + String(repeating: "0", count: 64)
            await #expect(throws: DaemonError.self) { try await h.connection.setWorkspaceMetadata(key, icon: .set(missing)) }
        }
    }
}
