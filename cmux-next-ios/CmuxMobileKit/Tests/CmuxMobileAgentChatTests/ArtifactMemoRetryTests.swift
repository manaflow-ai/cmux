import Foundation
import Testing
@testable import CmuxMobileArtifacts

/// The thumbnail grid is lazy: scrolling away cancels its task, and an
/// unavailable Mac can recover while the same iPhone process stays alive.
@Suite struct ArtifactMemoRetryTests {
    actor FlakyMake {
        enum First: Sendable { case unavailable, cancelled }
        let first: First
        private var calls = 0

        init(first: First) { self.first = first }

        func make() throws -> String? {
            calls += 1
            if calls == 1 {
                switch first {
                case .unavailable: throw ArtifactUnavailable("Connect to your Mac.")
                case .cancelled: throw CancellationError()
                }
            }
            return "ready"
        }
        func count() -> Int { calls }
    }

    let artifact = TerminalArtifact(reference: "session/README.md", kind: .markdown)

    @Test func unavailableMacDoesNotPoisonTheThumbnailMemo() async {
        let cache = ArtifactMemo<String>(costLimit: 1_024)
        let source = FlakyMake(first: .unavailable)
        let first = await cache.value(for: artifact) { _ in try await source.make() }
        #expect(first == nil)
        let second = await cache.value(for: artifact) { _ in try await source.make() }
        #expect(second == "ready")
        let again = await cache.value(for: artifact) { _ in "other" }
        #expect(again == "ready")
        #expect(cache.makesStarted == 2)
        #expect(await source.count() == 2)
    }

    @Test func cancelledLoadIsRetryable() async {
        let cache = ArtifactMemo<String>(costLimit: 1_024)
        let source = FlakyMake(first: .cancelled)
        #expect(await cache.value(for: artifact) { _ in try await source.make() } == nil)
        #expect(await cache.value(for: artifact) { _ in try await source.make() } == "ready")
        #expect(cache.makesStarted == 2)
    }

    @Test func successfullyLoadedButUnrenderableArtifactCachesNil() async {
        let cache = ArtifactMemo<String>(costLimit: 1_024)
        let first: String? = await cache.value(for: artifact) { _ in nil }
        let second: String? = await cache.value(for: artifact) { _ in "unexpected" }
        #expect(first == nil && second == nil)
        #expect(cache.makesStarted == 1)
    }
}

#if os(iOS)
/// Exercise the real thumbnail wrapper: an unavailable Mac is retried, while
/// a definitive missing file is an empty preview cached for this artifact.
@Suite struct ArtifactThumbnailRecoveryTests {
    actor Source: ArtifactSource {
        enum Mode: Sendable { case unavailableOnce, missing }
        let mode: Mode
        private var calls = 0
        init(_ mode: Mode) { self.mode = mode }

        func load(_ artifact: TerminalArtifact) async throws -> ArtifactContent {
            calls += 1
            if mode == .missing { throw ArtifactNotFound(reference: artifact.reference) }
            if calls == 1 { throw ArtifactUnavailable("Mac is offline") }
            return .text("line one\nline two")
        }
        func count() -> Int { calls }
    }

    @Test func previewRecoversAfterItsMacConnects() async {
        let cache = ArtifactMemo<ArtifactThumbnail>(costLimit: 1_024)
        let source = Source(.unavailableOnce)
        let artifact = TerminalArtifact(reference: "notes.md", kind: .markdown)
        let before = await cache.thumbnail(for: artifact, source: source, scale: 2)
        #expect(before == nil)
        let after = await cache.thumbnail(for: artifact, source: source, scale: 2)
        #expect(after == .excerpt("line one\nline two"))
        #expect(await source.count() == 2)
    }

    @Test func permanentlyMissingPreviewIsReadOnce() async {
        let cache = ArtifactMemo<ArtifactThumbnail>(costLimit: 1_024)
        let source = Source(.missing)
        let artifact = TerminalArtifact(reference: "gone.md", kind: .markdown)
        let before = await cache.thumbnail(for: artifact, source: source, scale: 2)
        let after = await cache.thumbnail(for: artifact, source: source, scale: 2)
        #expect(before == nil && after == nil)
        #expect(await source.count() == 1)
        #expect(cache.makesStarted == 1)
    }
}
#endif
