import CmuxNextFiles
@testable import CmuxNextApp
import CmuxNextDesign
import CmuxNextPages
import CmuxNextSettings
import Darwin
import Foundation
import Testing

/// Markdown table column widths outlive the tab (user 2026-10-20: "i close tab and reopen it and
/// the custom widths i set are gone"; plans/cmux-next/MARKDOWN-TABLE-WIDTHS-DESIGN.md). The host
/// keeps the page's value in the file's `com.cmux.markdown.tables` extended attribute and mirrors
/// it into an app-side copy, so a volume or an editor that drops attributes still keeps them. The
/// file's bytes and modification time never change.
@MainActor @Suite(.serialized) struct MarkdownTableWidthMemoryTests {
    private let folder: URL
    private let support: URL
    private let file: URL
    private static let value = Data(#"{"v":1,"tables":[{"i":0,"h":"2-0badf00d","w":[220,100]}]}"#.utf8)

    init() throws {
        let base = FileManager.default.temporaryDirectory.appending(path: "md-widths-\(UUID().uuidString)", directoryHint: .isDirectory)
        folder = base.appending(path: "docs", directoryHint: .isDirectory)
        support = base.appending(path: "support", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        file = folder.appending(path: "notes.md")
        try Data("| Name | Role |\n| --- | --- |\n| Ada | Engineer |\n".utf8).write(to: file)
    }

    /// A volume that refuses extended attributes (SMB, FAT, a read-only file).
    nonisolated private struct RefusingAttributes: ExtendedAttributeAccess {
        func read(_ name: String, at path: String) -> Data? { nil }
        func write(_ name: String, _ value: Data, at path: String) -> Bool { false }
        func remove(_ name: String, at path: String) -> Bool { false }
    }

    private func modified(_ url: URL) throws -> Date {
        try #require(try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date)
    }

    @Test func theWidthsLiveInTheFilesAttributeAndLeaveItsBytesAlone() async throws {
        let store = MarkdownTableWidthRepository(fallback: support)
        let bytes = try Data(contentsOf: file)
        let before = try modified(file)
        let written = await store.write(file.path, Self.value)
        #expect(written == MarkdownTableWidthWrite(attribute: true, fallback: true))
        #expect(DarwinExtendedAttributes().read(MarkdownTableWidthRepository.attributeName, at: file.path) == Self.value)
        #expect(try Data(contentsOf: file) == bytes)
        #expect(try modified(file) == before)
        // A new store (the app relaunched) reads them back.
        #expect(await MarkdownTableWidthRepository(fallback: support).read(file.path) == Self.value)
    }

    @Test func withoutAttributesTheAppSideCopyKeepsThem() async throws {
        let store = MarkdownTableWidthRepository(attributes: RefusingAttributes(), fallback: support)
        let written = await store.write(file.path, Self.value)
        #expect(written == MarkdownTableWidthWrite(attribute: false, fallback: true))
        #expect(await MarkdownTableWidthRepository(attributes: RefusingAttributes(), fallback: support).read(file.path) == Self.value)
        // Forgetting removes the copy too.
        await store.write(file.path, nil)
        #expect(await store.read(file.path) == nil)
    }

    @Test func anEditorThatReplacesTheFileDropsTheAttributeButNotTheWidths() async throws {
        let store = MarkdownTableWidthRepository(fallback: support)
        await store.write(file.path, Self.value)
        // An atomic save (most editors, git checkout) writes a new file and renames it over.
        try Data("| Name | Role |\n| --- | --- |\n| Ada | Admiral |\n".utf8).write(to: file, options: .atomic)
        #expect(DarwinExtendedAttributes().read(MarkdownTableWidthRepository.attributeName, at: file.path) == nil)
        #expect(await store.read(file.path) == Self.value)
    }

    @Test func forgettingClearsTheAttributeAndTheCopy() async throws {
        let store = MarkdownTableWidthRepository(fallback: support)
        await store.write(file.path, Self.value)
        let cleared = await store.write(file.path, nil)
        #expect(cleared == MarkdownTableWidthWrite(attribute: true, fallback: true))
        #expect(DarwinExtendedAttributes().read(MarkdownTableWidthRepository.attributeName, at: file.path) == nil)
        #expect(await store.read(file.path) == nil)
    }

    @Test func theAppSideCopyKeepsOnlyTheMostRecentFiles() async throws {
        let store = MarkdownTableWidthRepository(attributes: RefusingAttributes(), fallback: support, fallbackLimit: 3)
        // The copy is pruned on the first write and every pruneEvery writes after it.
        for index in 0...MarkdownTableWidthRepository.pruneEvery {
            await store.write(folder.appending(path: "f\(index).md").path, Self.value)
        }
        let kept = try FileManager.default.contentsOfDirectory(atPath: support.path)
        #expect(kept.count == 3)
        let last = folder.appending(path: "f\(MarkdownTableWidthRepository.pruneEvery).md").path
        #expect(await store.read(last) == Self.value)
    }

    /// Write cost: one write per finished resize. Printed for the report, bounded so a regression
    /// to something slow (a full-store rewrite, a write per drag frame) shows.
    @Test func aWriteCostsWellUnderAMillisecond() async throws {
        let store = MarkdownTableWidthRepository(fallback: support)
        let rounds = 200
        let clock = ContinuousClock()
        var samples: [Duration] = []
        for round in 0..<rounds {
            let value = Data(#"{"v":1,"tables":[{"i":0,"h":"2-0badf00d","w":[\#(100 + round),100]}]}"#.utf8)
            samples.append(await clock.measure { _ = await store.write(file.path, value) })
        }
        let attributeOnly = DarwinExtendedAttributes()
        var attributeSamples: [Duration] = []
        for _ in 0..<rounds {
            attributeSamples.append(clock.measure { _ = attributeOnly.write(MarkdownTableWidthRepository.attributeName, Self.value, at: file.path) })
        }
        func micros(_ samples: [Duration], _ quantile: Double) -> Double {
            let sorted = samples.sorted()
            let duration = sorted[min(sorted.count - 1, Int(Double(sorted.count) * quantile))]
            return Double(duration.components.attoseconds) / 1e12 + Double(duration.components.seconds) * 1e6
        }
        print("MARKDOWN-TABLE-WIDTHS write cost: attribute+copy p50 \(micros(samples, 0.5)) us, p95 \(micros(samples, 0.95)) us;"
              + " attribute only p50 \(micros(attributeSamples, 0.5)) us, p95 \(micros(attributeSamples, 0.95)) us")
        #expect(micros(samples, 0.5) < 2000)
    }

    // MARK: The page's host contract

    private final class Host: FilePageHosting {
        var roots: FileWorkspaceRoots { FileWorkspaceRoots(folders: []) }
        var remoteImages: Bool { false }
        func recents() -> JSONValue { ["items": []] }
        func record(_ url: URL) {}
        func chooseFile(start: URL?) async -> URL? { nil }
        func look() -> JSONValue { .object([:]) }
        func listenLook(_ onLook: @escaping @MainActor (JSONValue) -> Void) -> () -> Void { {} }
        func setPreference(key: String, value: JSONValue, by writer: SettingWriter) async throws {}
        func opened(_ url: URL) {}
        func openExternal(_ url: URL) {}
        func openFile(_ url: URL) {}
        func openAppLink(_ url: URL) -> Bool { false }
        func isRecent(_ path: String) -> Bool { false }
        func confirmOpen(_ url: URL, userGesture: Bool) async -> Bool { false }
        func edited(_ url: URL, text: String, baseHash: String?, writable: Bool) -> RecoveryDraftAcceptance { .kept }
        func saved(_ url: URL, hash: String) {}
    }

    private final class NoImages: RemoteImageFetching {
        func fetch(_ url: URL) async -> PageResource? { nil }
    }

    private func tab(_ store: MarkdownTableWidthRepository) -> FilePageProvider {
        FilePageProvider(kind: .markdown, file: file, host: Host(), libraries: nil, images: NoImages(), tableWidths: store)
    }

    private let context = PageCallContext(page: FilePageKind.markdown.namespace)

    @Test func aClosedAndReopenedTabGetsItsWidthsInTheFirstConfig() async throws {
        let store = MarkdownTableWidthRepository(fallback: support)
        let first = tab(store)
        let config = try await first.call("cmux.markdown.config", params: .object([:]), context: context)
        #expect(config["tableWidths"] == nil)
        let value = try JSONValue.parse(Self.value)
        let answer = try await first.call("cmux.markdown.setTableWidths",
                                          params: ["path": .string(file.path), "value": value], context: context)
        #expect(answer["attribute"]?.boolValue == true)
        first.close()

        let again = tab(MarkdownTableWidthRepository(fallback: support))
        defer { again.close() }
        let reopened = try await again.call("cmux.markdown.config", params: .object([:]), context: context)
        #expect(reopened["tableWidths"] == value)
        #expect(reopened["text"]?.stringValue == "| Name | Role |\n| --- | --- |\n| Ada | Engineer |\n")
    }

    @Test func thePageMaySaveOnlyItsOwnFileAndOnlyWidths() async throws {
        let provider = tab(MarkdownTableWidthRepository(fallback: support))
        defer { provider.close() }
        _ = try await provider.call("cmux.markdown.config", params: .object([:]), context: context)
        let other = folder.appending(path: "other.md")
        try Data("x".utf8).write(to: other)
        await #expect(throws: PageError.self) {
            _ = try await provider.call("cmux.markdown.setTableWidths",
                                        params: ["path": .string(other.path), "value": try JSONValue.parse(Self.value)], context: context)
        }
        await #expect(throws: PageError.self) {
            _ = try await provider.call("cmux.markdown.setTableWidths",
                                        params: ["path": .string(file.path), "value": ["text": "not widths"]], context: context)
        }
        #expect(DarwinExtendedAttributes().read(MarkdownTableWidthRepository.attributeName, at: other.path) == nil)
    }

    @Test func theRightClickedTableIsWhatTheMenuResets() async throws {
        let provider = tab(MarkdownTableWidthRepository(fallback: support))
        defer { provider.close() }
        _ = try await provider.call("cmux.markdown.contextTable", params: ["table": 1], context: context)
        #expect(provider.contextTable == 1)
        _ = try await provider.call("cmux.markdown.contextTable", params: ["table": .null], context: context)
        #expect(provider.contextTable == nil)
    }
}
