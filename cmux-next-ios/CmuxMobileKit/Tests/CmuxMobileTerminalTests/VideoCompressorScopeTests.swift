#if os(iOS)
import CmuxMobileArtifacts
import CmuxMobileTransport
import Foundation
import Testing
@testable import CmuxMobileTerminal

@Suite struct VideoCompressorScopeTests {
    /// Makes a real movie visible at the picked URL only while its scope is open.
    private struct MovieScope: SecurityScope {
        let movie: URL
        var cancelWhenOpened = false

        func startAccessing(_ url: URL) -> Bool {
            do {
                try FileManager.default.linkItem(at: movie, to: url)
                if cancelWhenOpened { withUnsafeCurrentTask { $0?.cancel() } }
                return true
            } catch {
                Issue.record("Could not expose the movie at the picked URL: \(error)")
                return false
            }
        }

        func stopAccessing(_ url: URL) {
            do {
                try FileManager.default.removeItem(at: url)
            } catch {
                Issue.record("Could not release the picked URL: \(error)")
            }
        }
    }

    @Test func filePickerMovieCanBeInspectedAndAccessIsReleasedOnReturnOrCancellation() async throws {
        let movie = try await MockArtifactSource.recordingURL()
        let picked = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("mp4")
        for cancel in [false, true] {
            let file = ScopedFile(picked, scope: MovieScope(movie: movie, cancelWhenOpened: cancel))
            let result = await Task { await VideoCompressor.prepare(file) { _ in } }.value
            if cancel {
                #expect(result.plan == nil)
            } else {
                // A plan means AVFoundation actually read the track and its duration.
                #expect(result.plan?.reencode == false)
            }
            #expect(result.output == nil)
            #expect(!FileManager.default.fileExists(atPath: picked.path))
        }
    }
}
#endif
