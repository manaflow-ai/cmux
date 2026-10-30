@testable import CmuxNextUpdater
import Foundation
import Testing

struct ReleaseMediaStoreTests {
    @Test func inlinesAnIsoBmffVideoAsVideoData() {
        let bytes = Data([0, 0, 0, 24, 0x66, 0x74, 0x79, 0x70, 0x69, 0x73, 0x6F, 0x6D, 0, 0, 0, 0,
                          0x69, 0x73, 0x6F, 0x6D, 0x6D, 0x70, 0x34, 0x32])
        #expect(ReleaseMediaStore.kind(of: bytes) == .video)
        #expect(ReleaseMediaStore.admits(bytes))
        #expect(ReleaseMediaStore.dataURL(bytes)?.absoluteString.hasPrefix("data:video/mp4;base64,") == true)
    }

    @Test func acceptsOnlyThePublicCmuxMediaBranch() {
        #expect(ReleaseMediaStore.isPublicHighlightURL(URL(string: "https://raw.githubusercontent.com/manaflow-ai/cmux/pr-media/25135/after.png")!))
        #expect(!ReleaseMediaStore.isPublicHighlightURL(URL(string: "https://raw.githubusercontent.com/someone/cmux/pr-media/25135/after.png")!))
        #expect(!ReleaseMediaStore.isPublicHighlightURL(URL(string: "https://raw.githubusercontent.com/manaflow-ai/cmux/pr-media/25135/after.png?redirect=elsewhere")!))
        #expect(!ReleaseMediaStore.isPublicHighlightURL(URL(string: "https://raw.githubusercontent.com.evil.example/manaflow-ai/cmux/pr-media/after.png")!))
        #expect(!ReleaseMediaStore.isPublicHighlightURL(URL(string: "https://raw.githubusercontent.com/manaflow-ai/cmux/pr-media/../main/file.png")!))
        #expect(!ReleaseMediaStore.isPublicHighlightURL(URL(string: "https://raw.githubusercontent.com/manaflow-ai/cmux/pr-media/%2e%2e/main/file.png")!))
        #expect(URL(string: "https://raw.githubusercontent.com:bad/manaflow-ai/cmux/pr-media/after.png").map { !ReleaseMediaStore.isPublicHighlightURL($0) } ?? true)
    }
}
