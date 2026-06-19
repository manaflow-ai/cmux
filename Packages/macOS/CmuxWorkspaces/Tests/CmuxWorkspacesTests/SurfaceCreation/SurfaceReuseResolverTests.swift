import Foundation
import Testing

@testable import CmuxWorkspaces

@Suite("SurfaceReuseResolver")
struct SurfaceReuseResolverTests {
    private let resolver = SurfaceReuseResolver()

    @Test("Empty candidate list always creates")
    func emptyCreates() {
        let decision = resolver.decision(
            candidates: [SurfaceReuseCandidate<String>](),
            requestedKey: "/tmp/a.md",
            shouldFocusExisting: true
        )
        #expect(decision == .create)
    }

    @Test("No matching key creates")
    func noMatchCreates() {
        let candidates = [
            SurfaceReuseCandidate(panelId: UUID(), key: "/tmp/a.md"),
            SurfaceReuseCandidate(panelId: UUID(), key: "/tmp/b.md"),
        ]
        let decision = resolver.decision(
            candidates: candidates,
            requestedKey: "/tmp/c.md",
            shouldFocusExisting: true
        )
        #expect(decision == .create)
    }

    @Test("First matching candidate is reused in iteration order")
    func firstMatchWins() {
        let first = UUID()
        let second = UUID()
        let candidates = [
            SurfaceReuseCandidate(panelId: first, key: "/tmp/a.md"),
            SurfaceReuseCandidate(panelId: second, key: "/tmp/a.md"),
        ]
        let decision = resolver.decision(
            candidates: candidates,
            requestedKey: "/tmp/a.md",
            shouldFocusExisting: true
        )
        #expect(decision == .focusExisting(panelId: first, shouldFocus: true))
    }

    @Test("shouldFocusExisting flows through to the decision")
    func focusFlagPropagates() {
        let panelId = UUID()
        let candidates = [SurfaceReuseCandidate(panelId: panelId, key: "/tmp/a.md")]
        let focused = resolver.decision(
            candidates: candidates,
            requestedKey: "/tmp/a.md",
            shouldFocusExisting: true
        )
        let unfocused = resolver.decision(
            candidates: candidates,
            requestedKey: "/tmp/a.md",
            shouldFocusExisting: false
        )
        #expect(focused == .focusExisting(panelId: panelId, shouldFocus: true))
        #expect(unfocused == .focusExisting(panelId: panelId, shouldFocus: false))
    }

    @Test("Works with a non-string Hashable key (right sidebar mode stand-in)")
    func nonStringKey() {
        enum Mode: Hashable, Sendable { case diff, search, terminal }
        let diffPanel = UUID()
        let candidates = [
            SurfaceReuseCandidate(panelId: diffPanel, key: Mode.diff),
            SurfaceReuseCandidate(panelId: UUID(), key: Mode.search),
        ]
        #expect(
            resolver.decision(candidates: candidates, requestedKey: Mode.diff, shouldFocusExisting: false)
                == .focusExisting(panelId: diffPanel, shouldFocus: false)
        )
        #expect(
            resolver.decision(candidates: candidates, requestedKey: Mode.terminal, shouldFocusExisting: true)
                == .create
        )
    }
}

@Suite("String.surfaceFilePathIdentity")
struct SurfaceFilePathIdentityTests {
    @Test("Identical paths share an identity")
    func identicalPaths() {
        #expect("/tmp/a.md".surfaceFilePathIdentity == "/tmp/a.md".surfaceFilePathIdentity)
    }

    @Test("A real symlink resolves to its target's identity")
    func symlinkResolves() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }

        let target = dir.appendingPathComponent("real.md")
        try "# hi".write(to: target, atomically: true, encoding: .utf8)
        let link = dir.appendingPathComponent("link.md")
        try fm.createSymbolicLink(at: link, withDestinationURL: target)

        // The resolved-symlink identity of the link equals that of the target.
        #expect(link.path.surfaceFilePathIdentity == target.path.surfaceFilePathIdentity)
    }
}
