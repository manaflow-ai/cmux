import CmuxAgentChat
@testable import CmuxGit
import Foundation
import Testing

@Suite struct ScratchLiveRepoProbeTests {
    @Test func liveDemoRepoCurrentFetch() async throws {
        let repo = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache/cmux-diffv-demo/repo").path
        guard FileManager.default.fileExists(atPath: repo) else { return }
        let service = WorkspaceChangesService()
        let stat = try await service.fileStat(
            forDirectory: repo, path: "Assets/AppMark.png", revision: .current
        )
        print("PROBE stat kind=\(stat.kind) size=\(stat.size) mime=\(stat.mimeType ?? "-")")
        let chunk = try await service.fileFetch(
            forDirectory: repo, path: "Assets/AppMark.png", revision: .current,
            offset: 0, length: 1024
        )
        print("PROBE fetch bytes=\(chunk.data.count) total=\(chunk.totalSize) eof=\(chunk.eof)")
        #expect(chunk.data.count > 0)
        #expect(chunk.eof)
    }
}
