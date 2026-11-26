import Foundation
import Testing

@testable import CmuxAgentChat

@Suite("Terminal artifact authorization snapshots")
struct TerminalArtifactAuthorizationStoreTests {
    @Test("a listed path remains authorized after it scrolls off screen")
    func listedPathSurvivesLiveScreenChange() async {
        let listedPath = "/safe/report.txt"
        let scanScope = TerminalArtifactScope(
            terminalText: "open \(listedPath)",
            workingDirectory: "/safe",
            resolver: FakeResolver(files: [listedPath])
        )
        let listedPaths = Set(scanScope.artifactPaths())
        let liveScopeAfterScroll = TerminalArtifactScope(
            terminalText: "prompt with no artifact path",
            workingDirectory: "/safe",
            resolver: FakeResolver(files: [listedPath])
        )
        let store = TerminalArtifactAuthorizationStore(
            timeToLive: 60,
            maximumGenerationsPerSurface: 2
        )
        let scannedAt = Date(timeIntervalSince1970: 100)

        await store.record(
            workspaceID: "workspace",
            surfaceID: "surface",
            canonicalPaths: listedPaths,
            at: scannedAt
        )
        let snapshotPaths = await store.authorizedPaths(
            workspaceID: "workspace",
            surfaceID: "surface",
            at: scannedAt.addingTimeInterval(30)
        )
        let snapshotScope = ChatArtifactScope(
            referencedPaths: snapshotPaths,
            resolver: FakeResolver(files: [listedPath])
        )

        #expect(liveScopeAfterScroll.canonicalPath(for: listedPath) == nil)
        #expect(snapshotScope.canonicalFilePath(for: listedPath) == listedPath)
    }

    @Test("authorization is bounded by TTL and retained generations")
    func boundedLifetimeAndGenerations() async {
        let store = TerminalArtifactAuthorizationStore(
            timeToLive: 60,
            maximumGenerationsPerSurface: 2
        )
        let start = Date(timeIntervalSince1970: 100)

        await store.record(
            workspaceID: "workspace",
            surfaceID: "surface",
            canonicalPaths: ["/safe/one.txt"],
            at: start
        )
        await store.record(
            workspaceID: "workspace",
            surfaceID: "surface",
            canonicalPaths: ["/safe/two.txt"],
            at: start.addingTimeInterval(1)
        )
        await store.record(
            workspaceID: "workspace",
            surfaceID: "surface",
            canonicalPaths: ["/safe/three.txt"],
            at: start.addingTimeInterval(2)
        )

        #expect(await store.authorizedPaths(
            workspaceID: "workspace",
            surfaceID: "surface",
            at: start.addingTimeInterval(30)
        ) == ["/safe/two.txt", "/safe/three.txt"])
        #expect(await store.authorizedPaths(
            workspaceID: "workspace",
            surfaceID: "surface",
            at: start.addingTimeInterval(63)
        ).isEmpty)
    }

    private struct FakeResolver: ChatArtifactScope.FileSystemResolving {
        let files: Set<String>

        func resolveSymlinks(of path: String) -> String? {
            (path as NSString).standardizingPath
        }

        func isDirectory(_ path: String) -> Bool? {
            files.contains(path) ? false : nil
        }
    }
}
