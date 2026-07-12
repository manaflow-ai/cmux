import Foundation
import Testing
@testable import CmuxMobileBrowser

@Suite("Mobile diff patch store")
@MainActor
struct MobileDiffPatchStoreTests {
    @Test("Configured content is available synchronously")
    func configuredContentIsSynchronous() async throws {
        let store = MobileDiffPatchStore(resourceRoot: nil)
        await store.configure(generation: 7, html: Data("html".utf8), patch: Data("patch".utf8))

        let html = try #require(store.content(for: "/index-7.html"))
        let patch = try #require(store.content(for: "/patch/current-7.diff"))

        #expect(html.data == Data("html".utf8))
        #expect(patch.data == Data("patch".utf8))
    }
}
