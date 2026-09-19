import AppKit
import Combine
import Foundation
import Testing

@testable import CmuxSidebar

private struct FixedLogLimitProvider: SidebarLogEntryLimitProviding {
    let configuredMaxSidebarLogEntries: Int?
}

@MainActor
@Suite struct WorkspaceSidebarMetadataModelTests {
    private func makeModel(limit: Int? = nil) -> WorkspaceSidebarMetadataModel {
        WorkspaceSidebarMetadataModel(limitProvider: FixedLogLimitProvider(configuredMaxSidebarLogEntries: limit))
    }

    @Test func addStatusEntryKeysByEntryKey() {
        let model = makeModel()
        let entry = SidebarStatusEntry(
            key: "agent",
            value: "running",
            icon: nil,
            color: nil,
            url: nil,
            priority: 1,
            format: .plain,
            timestamp: Date(timeIntervalSince1970: 1)
        )
        model.addStatusEntry(entry)
        #expect(model.statusEntries["agent"] == entry)
    }

    @Test(arguments: [
        ("bolt.fill", SidebarStatusIcon.systemSymbol("bolt.fill")),
        ("sf:hammer", SidebarStatusIcon.systemSymbol("hammer")),
        ("emoji: 🚀 ", SidebarStatusIcon.emoji("🚀")),
        ("text: CI ", SidebarStatusIcon.text("CI")),
        ("image: ~/.config/cmux/icons/codex.png ", SidebarStatusIcon.imageFile("~/.config/cmux/icons/codex.png")),
    ])
    func statusIconParsesSupportedTokens(_ token: String, _ expected: SidebarStatusIcon) {
        #expect(SidebarStatusIcon(token: token) == expected)
    }

    @Test(arguments: [nil, "", "   ", "image:", "emoji:  ", "sf:\n"])
    func statusIconRejectsEmptyTokens(_ token: String?) {
        #expect(SidebarStatusIcon(token: token) == nil)
    }

    @Test func statusImageLoaderReadsColorAssetAndRejectsUnsafeInputs() async throws {
        let bitmap = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 2,
            pixelsHigh: 2,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ))
        bitmap.setColor(.systemRed, atX: 0, y: 0)
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-status-icons-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let imageURL = directory.appendingPathComponent("agent.png")
        let oversizedURL = directory.appendingPathComponent("oversized.png")
        let unsupportedURL = directory.appendingPathComponent("agent.svg")
        try data.write(to: imageURL)
        try Data(count: 1_000_001).write(to: oversizedURL)
        try data.write(to: unsupportedURL)
        let loader = SidebarStatusIconImageLoader(fileReader: SidebarStatusIconFileReader())

        let loaded = try #require(await loader.image(at: imageURL.path))
        #expect(loaded.width == 2)
        #expect(loaded.height == 2)
        #expect(await loader.image(at: "agent.png") == nil)
        #expect(await loader.image(at: oversizedURL.path) == nil)
        #expect(await loader.image(at: unsupportedURL.path) == nil)
    }

    @Test func statusImageLoaderRejectsExcessiveDecodedDimensions() async throws {
        let bitmap = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 2_049,
            pixelsHigh: 2_049,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ))
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-oversized-status-icon-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: fileURL) }
        try data.write(to: fileURL)
        let loader = SidebarStatusIconImageLoader(fileReader: SidebarStatusIconFileReader())

        #expect(await loader.image(at: fileURL.path) == nil)
    }

    @Test func statusImageLoaderRefreshesCachedPathAfterFileReplacement() async throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-replaced-status-icon-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let firstBitmap = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 2,
            pixelsHigh: 2,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ))
        let firstData = try #require(firstBitmap.representation(using: .png, properties: [:]))
        try firstData.write(to: fileURL, options: .atomic)

        let loader = SidebarStatusIconImageLoader(fileReader: SidebarStatusIconFileReader())
        let firstImage = try #require(await loader.image(at: fileURL.path))
        #expect(firstImage.width == 2)

        let replacementBitmap = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 3,
            pixelsHigh: 3,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ))
        let replacementData = try #require(replacementBitmap.representation(using: .png, properties: [:]))
        try replacementData.write(to: fileURL, options: .atomic)

        let replacementImage = try #require(await loader.image(at: fileURL.path))
        #expect(replacementImage.width == 3)
    }

    @Test func statusIconFileReaderRejectsIntMaxByteLimit() throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-status-icon-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: fileURL) }
        try Data([0x01]).write(to: fileURL)

        let reader = SidebarStatusIconFileReader()
        #expect(reader.data(at: fileURL.path, maximumByteCount: .max) == nil)
    }

    @Test func appendLogEntryTrimsAndDropsEmpty() {
        let model = makeModel()
        model.appendLogEntry(message: "   ", level: .info, source: nil)
        #expect(model.logEntries.isEmpty)
        model.appendLogEntry(message: "  hello  ", level: .info, source: "src")
        #expect(model.logEntries.count == 1)
        #expect(model.logEntries[0].message == "hello")
        #expect(model.logEntries[0].source == "src")
    }

    @Test func appendLogEntryDefaultsToFiftyWhenUnset() {
        let model = makeModel(limit: nil)
        for index in 0..<60 {
            model.appendLogEntry(message: "m\(index)", level: .info, source: nil)
        }
        #expect(model.logEntries.count == 50)
        // Oldest entries trimmed: the buffer keeps the most recent 50.
        #expect(model.logEntries.first?.message == "m10")
        #expect(model.logEntries.last?.message == "m59")
    }

    @Test func appendLogEntryClampsLimitToOne() {
        let model = makeModel(limit: 0)
        model.appendLogEntry(message: "a", level: .info, source: nil)
        model.appendLogEntry(message: "b", level: .info, source: nil)
        #expect(model.logEntries.count == 1)
        #expect(model.logEntries.last?.message == "b")
    }

    @Test func appendLogEntryClampsLimitToFiveHundred() {
        let model = makeModel(limit: 100_000)
        for index in 0..<600 {
            model.appendLogEntry(message: "m\(index)", level: .info, source: nil)
        }
        #expect(model.logEntries.count == 500)
    }

    @Test func metadataBlocksInDisplayOrderSortsByPriorityTimestampKey() {
        let model = makeModel()
        let low = SidebarMetadataBlock(key: "b", markdown: "x", priority: 1, timestamp: Date(timeIntervalSince1970: 10))
        let highOld = SidebarMetadataBlock(key: "a", markdown: "y", priority: 5, timestamp: Date(timeIntervalSince1970: 1))
        let highNew = SidebarMetadataBlock(key: "c", markdown: "z", priority: 5, timestamp: Date(timeIntervalSince1970: 9))
        model.metadataBlocks = ["b": low, "a": highOld, "c": highNew]
        let ordered = model.metadataBlocksInDisplayOrder()
        #expect(ordered.map(\.key) == ["c", "a", "b"])
    }

    @Test func progressGitAndPullRequestUpdaters() {
        let model = makeModel()
        model.updateProgress(SidebarProgressState(value: 0.5, label: "half"))
        #expect(model.progress?.label == "half")
        model.updateProgress(nil)
        #expect(model.progress == nil)

        model.updateGitBranch(SidebarGitBranchState(branch: "main", isDirty: true))
        #expect(model.gitBranch?.branch == "main")
        #expect(model.gitBranch?.isDirty == true)

        let pr = SidebarPullRequestState(
            number: 7,
            label: "PR 7",
            url: URL(string: "https://example.com/7")!,
            status: .open,
            branch: "feat",
            isStale: false
        )
        model.updatePullRequest(pr)
        #expect(model.pullRequest?.number == 7)
    }

    @Test func publisherSeedsCurrentValueThenEmitsChanges() {
        let model = makeModel()
        var received: [Int] = []
        let cancellable = model.statusEntriesPublisher
            .map(\.count)
            .sink { received.append($0) }
        defer { cancellable.cancel() }

        // Seeds with the current (empty) value immediately.
        #expect(received == [0])

        model.addStatusEntry(
            SidebarStatusEntry(
                key: "k",
                value: "v",
                icon: nil,
                color: nil,
                url: nil,
                priority: 0,
                format: .plain,
                timestamp: Date(timeIntervalSince1970: 1)
            )
        )
        #expect(received == [0, 1])
    }

    @Test func panelMapsForwardThroughStoredProperties() {
        let model = makeModel()
        let id = UUID()
        model.panelGitBranches[id] = SidebarGitBranchState(branch: "dev", isDirty: false)
        #expect(model.panelGitBranches[id]?.branch == "dev")
        model.panelGitBranches.removeValue(forKey: id)
        #expect(model.panelGitBranches[id] == nil)
    }

    @Test func panelDirectoryDisplayLabelsStoreAndPublish() {
        let model = makeModel()
        let id = UUID()
        var emitted: [[UUID: String]] = []
        var cancellables: Set<AnyCancellable> = []
        model.panelDirectoryDisplayLabelsPublisher
            .sink { emitted.append($0) }
            .store(in: &cancellables)
        #expect(emitted == [[:]])

        model.panelDirectoryDisplayLabels[id] = "MyPackage  mainline"
        #expect(model.panelDirectoryDisplayLabels[id] == "MyPackage  mainline")
        model.panelDirectoryDisplayLabels.removeValue(forKey: id)
        #expect(model.panelDirectoryDisplayLabels[id] == nil)
        #expect(emitted.count == 3)
        #expect(emitted.last == [:])
    }
}
