import Foundation
import Testing
@testable import CmuxBrowser

@Suite("OWL native navigation state")
struct OwlNavigationStateTests {
    @Test("Foundation JSON numbers stay numeric while booleans stay boolean")
    func cdpJSONNumberDiscrimination() throws {
        let zero = try JSONSerialization.jsonObject(with: Data("0".utf8))
        let one = try JSONSerialization.jsonObject(with: Data("1".utf8))
        let boolean = try JSONSerialization.jsonObject(with: Data("true".utf8))

        #expect(CDPValue(any: zero) == .number(0))
        #expect(CDPValue(any: one) == .number(1))
        #expect(CDPValue(any: boolean) == .bool(true))
    }

    @Test("OWL mouse kinds match the fork's Mojo enum")
    func mouseKindMapping() {
        #expect(OwlFreshMouseKind(cdpType: "mousePressed") == .down)
        #expect(OwlFreshMouseKind(cdpType: "mouseReleased") == .up)
        #expect(OwlFreshMouseKind(cdpType: "mouseMoved") == .move)
        #expect(OwlFreshMouseKind(cdpType: "mouseWheel") == .wheel)
    }

    @Test("OWL extension launcher preserves the runtime layout")
    func owlExtensionLauncher() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-owl-wrapper-\(UUID().uuidString)", isDirectory: true)
        let shell = root
            .appendingPathComponent("Content Shell.app/Contents/MacOS/Content Shell", isDirectory: false)
        let extensionOne = root.appendingPathComponent("extension-one", isDirectory: true)
        let extensionTwo = root.appendingPathComponent("extension-two", isDirectory: true)
        let launcherDirectory = root.appendingPathComponent("profile", isDirectory: true)
        try FileManager.default.createDirectory(
            at: shell.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(at: extensionOne, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: extensionTwo, withIntermediateDirectories: true)
        try Data().write(to: shell)
        defer { try? FileManager.default.removeItem(at: root) }

        let wrapper = try OwlFreshRuntime.shellExecutable(
            for: shell,
            extensionDirectories: [extensionOne, extensionTwo],
            wrapperDirectory: launcherDirectory
        )
        #expect(wrapper.deletingLastPathComponent() == launcherDirectory)
        #expect(wrapper != shell)
        #expect(!wrapper.path.contains("Content Shell.app/Contents/MacOS"))
        #expect(FileManager.default.isExecutableFile(atPath: wrapper.path))
        let script = try String(contentsOf: wrapper, encoding: .utf8)
        #expect(script.contains("--disable-extensions-except=\(extensionOne.path),\(extensionTwo.path)"))
        #expect(script.contains("--load-extension=\(extensionOne.path),\(extensionTwo.path)"))
    }

    @Test("OWL extension snapshots stay owned and profile scoped")
    func extensionSnapshotsAreProfileScoped() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-owl-extension-store-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }

        let source = root.appendingPathComponent("source", isDirectory: true)
        try fileManager.createDirectory(at: source, withIntermediateDirectories: true)
        let manifest = "\"manifest_version\":3,\"name\":\"OWL test\",\"version\":\"1.0.0\",\"background\":{\"service_worker\":\"worker.js\"}"
        try Data(("{" + manifest + "}").utf8).write(to: source.appendingPathComponent("manifest.json"))
        try Data("self.owlTest = true;".utf8).write(to: source.appendingPathComponent("worker.js"))

        let storage = ChromiumOwnedStorage(
            fileManager: fileManager,
            applicationSupportURLProvider: { root },
            bundleIdentifierProvider: { "com.example.owl-extension-store" }
        )
        let store = ChromiumExtensionStore(storage: storage)
        let firstProfile = UUID()
        let secondProfile = UUID()
        let firstSnapshot = try await store.prepare(
            directories: [source.path],
            profileID: firstProfile
        )
        let repeatSnapshot = try await store.prepare(
            directories: [source.path],
            profileID: firstProfile
        )
        let secondSnapshot = try await store.prepare(
            directories: [source.path],
            profileID: secondProfile
        )

        #expect(firstSnapshot.count == 1)
        #expect(firstSnapshot == repeatSnapshot)
        #expect(firstSnapshot.first != source)
        #expect(secondSnapshot.first != firstSnapshot.first)
        let snapshotManifest = try JSONSerialization.jsonObject(
            with: Data(contentsOf: firstSnapshot[0].appendingPathComponent("manifest.json"))
        ) as? [String: Any]
        #expect(snapshotManifest?["key"] as? String != nil)
    }

    @Test("OWL statement evaluation preserves a trailing completion expression")
    func statementBodyPreservesCompletionValue() {
        let body = OwlFreshRuntime.owlStatementBody(for: "const answer = 21; answer;")
        #expect(body.contains("const answer = 21;"))
        #expect(body.contains("return await (answer);"))
    }

    @Test("OWL statement evaluation keeps compact control programs as statements")
    func statementBodyKeepsCompactControlPrograms() {
        #expect(OwlFreshRuntime.owlStatementBody(for: "if(x) y;") == "if(x) y")
        #expect(OwlFreshRuntime.owlStatementBody(for: ";") == "return undefined;")
    }

    @Test("OWL history reports no-op traversal at either edge")
    func historyNoOps() {
        let first = URL(string: "https://one.example")!
        let second = URL(string: "https://two.example")!
        var history = OwlNavigationHistoryState(initialURL: first)

        #expect(history.targetURL(offset: -1) == nil)
        #expect(history.targetURL(offset: 1) == nil)
        history.commitDestination(second)
        #expect(history.canGoBack)
        #expect(!history.canGoForward)
        #expect(history.targetURL(offset: -1) == first)
        #expect(history.targetURL(offset: 1) == nil)
        history.commitTraversal(to: first)
        #expect(!history.canGoBack)
        #expect(history.canGoForward)
    }

    @Test("OWL traversal preserves the cursor when URLs repeat")
    func traversalPreservesDuplicateURLCursor() {
        let first = URL(string: "https://one.example")!
        let second = URL(string: "https://two.example")!
        var history = OwlNavigationHistoryState(initialURL: first)
        history.commitDestination(second)
        history.commitDestination(first)

        history.commitTraversal(to: second, offset: -1)
        #expect(history.canGoBack)
        #expect(history.canGoForward)
        history.commitTraversal(to: first, offset: 1)
        #expect(!history.canGoForward)
    }

    @Test("OWL traversal treats an HTTP origin slash as equivalent")
    func traversalNormalizesHTTPOriginSlash() {
        let origin = URL(string: "https://one.example")!
        let second = URL(string: "https://two.example/path")!
        var history = OwlNavigationHistoryState(initialURL: origin)
        history.commitDestination(second)

        history.commitTraversal(
            to: URL(string: "https://one.example/")!,
            offset: -1
        )
        #expect(!history.canGoBack)
        #expect(history.canGoForward)
    }

    @Test("OWL traversal mismatch does not rewrite history")
    func traversalMismatchDoesNotRewriteHistory() {
        let first = URL(string: "https://one.example")!
        let second = URL(string: "https://two.example")!
        var history = OwlNavigationHistoryState(initialURL: first)
        history.commitDestination(second)
        history.commitTraversal(to: URL(string: "https://other.example")!, offset: -1)
        #expect(history.canGoBack)
        #expect(!history.canGoForward)
    }

    @Test("OWL title-only events cannot complete a navigation")
    func titleOnlyEventsDoNotComplete() {
        #expect(!OwlNavigationCompletionPredicate.accepts(
            loading: false,
            sawLoadingEvent: false,
            targetMatches: true
        ))
        #expect(!OwlNavigationCompletionPredicate.accepts(
            loading: false,
            sawLoadingEvent: true,
            targetMatches: false
        ))
        #expect(!OwlNavigationCompletionPredicate.accepts(
            loading: true,
            sawLoadingEvent: true,
            targetMatches: true
        ))
        #expect(OwlNavigationCompletionPredicate.accepts(
            loading: false,
            sawLoadingEvent: true,
            targetMatches: true
        ))
    }

    @Test("OWL readiness requires a fresh complete document")
    func readinessRequiresFreshDocument() {
        #expect(!OwlNavigationCompletionPredicate.readinessAccepts(
            sawLoadingEvent: false,
            targetMatches: true,
            readyState: "complete",
            documentEpochAdvanced: true,
            requiresReloadNavigation: false,
            navigationType: "navigate"
        ))
        #expect(!OwlNavigationCompletionPredicate.readinessAccepts(
            sawLoadingEvent: true,
            targetMatches: true,
            readyState: "complete",
            documentEpochAdvanced: false,
            requiresReloadNavigation: false,
            navigationType: "navigate"
        ))
        #expect(!OwlNavigationCompletionPredicate.readinessAccepts(
            sawLoadingEvent: true,
            targetMatches: false,
            readyState: "complete",
            documentEpochAdvanced: true,
            requiresReloadNavigation: false,
            navigationType: "navigate"
        ))
        #expect(!OwlNavigationCompletionPredicate.readinessAccepts(
            sawLoadingEvent: true,
            targetMatches: true,
            readyState: "complete",
            documentEpochAdvanced: true,
            requiresReloadNavigation: true,
            navigationType: "back_forward"
        ))
        #expect(OwlNavigationCompletionPredicate.readinessAccepts(
            sawLoadingEvent: true,
            targetMatches: true,
            readyState: "complete",
            documentEpochAdvanced: true,
            requiresReloadNavigation: false,
            navigationType: "navigate"
        ))
        #expect(OwlNavigationCompletionPredicate.readinessAccepts(
            sawLoadingEvent: true,
            targetMatches: true,
            readyState: "complete",
            documentEpochAdvanced: true,
            requiresReloadNavigation: true,
            navigationType: "reload"
        ))
    }
}
