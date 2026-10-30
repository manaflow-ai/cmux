#if DEBUG
import CmuxNextMemory
@testable import CmuxNextPages
import CmuxNextPagesTestSupport
import Foundation
import Testing

/// Every page in a host with a release sink frees its script runs off the main thread: the host hands
/// its sink to each page it opens, and ``WebUIHost/pagesFreeingScriptsOnMain()`` (which ``WebUIHost/open(_:)``
/// asserts empty in DEBUG) names a page its registry lists that was made outside the host without one (P-MAIN S3).
@MainActor
struct WebUIHostScriptReleaseTests {
    private let root: URL
    private let descriptor = PageDescriptor(id: "test.script-release", resource: "script-release", processGroup: .solo, namespaces: [])

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("script-release-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("<!doctype html><title>Page</title>".utf8).write(to: root.appendingPathComponent("index.html"))
    }

    private func makeHost(sink: MemoryReleaseSink?) -> WebUIHost {
        let host = WebUIHost(chromium: nil, openPanel: nil, memory: QuietMemoryRegistry(), deadlines: LifecycleDeadlineRig.never)
        host.scriptReleaseSink = sink
        return host
    }

    @Test func aHostWithASinkGivesItToEveryPageItOpens() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let host = makeHost(sink: MemoryReleaseSink())
        let view = try #require(host.open(PageOpenRequest(descriptor: descriptor, root: root, routes: [])))
        defer { host.close(view) }
        #expect(view.releasesScriptsOffMain)
        #expect(host.pagesFreeingScriptsOnMain().isEmpty)
    }

    @Test func aPageMadeOutsideTheHostWithoutASinkIsNamed() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let host = makeHost(sink: MemoryReleaseSink())
        let opened = try #require(host.open(PageOpenRequest(descriptor: descriptor, root: root, routes: [])))
        defer { host.close(opened) }
        // Listed in the host's registry, but not opened by the host: no sink.
        let stray = try #require(PageWebView(request: PageOpenRequest(descriptor: descriptor, root: root, routes: []),
                                             chromium: nil, openPanel: nil, registry: host.registry,
                                             deadlines: LifecycleDeadlineRig.never))
        defer { host.close(stray) }
        #expect(!stray.releasesScriptsOffMain)
        #expect(host.pagesFreeingScriptsOnMain() == [stray])
    }

    @Test func aHostWithoutASinkChecksNothing() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let host = makeHost(sink: nil)
        let view = try #require(host.open(PageOpenRequest(descriptor: descriptor, root: root, routes: [])))
        defer { host.close(view) }
        #expect(!view.releasesScriptsOffMain)
        #expect(host.pagesFreeingScriptsOnMain().isEmpty)
    }
}
#endif
