import AppKit
@testable import CmuxNextApp
@testable import CmuxNextHome
import MessagesLabHome
import Testing

/// A link chip's hover card (Lawrence 2026-10-20: "hover on it and it'll show a preview of what I
/// will be jumping to"): the card shows the target's title, state, place and lines; the app reads
/// a file's first lines off disk and names a missing one; plans/cmux-next/home-link-chips-DESIGN.md.
@MainActor @Suite(.serialized) struct HomeLinkPreviewTests {
    /// AppServices reads `NSApp` (an implicitly unwrapped Optional) from its observers and services;
    /// a suite run in its own process has no shared application until something makes it.
    init() { _ = NSApplication.shared }

    @Test func theCardShowsTitleStatePlaceAndLines() {
        let card = HomeLinkPreviewCardView()
        card.configure(HomeLinkPreview(kind: .terminal, title: "build log", place: "Chief · audio · ~/fun/cmux", status: "Open",
                                       statusTone: .success, lines: ["Compiling", "Build succeeded"], monospaced: true))
        #expect(card.reportedLines == ["build log", "Open", "Chief · audio · ~/fun/cmux", "Compiling", "Build succeeded"])
        #expect(card.titleLabel.stringValue == "build log")
        #expect(!card.statusLabel.isHidden)
        #expect(!card.linesLabel.isHidden)
        #expect(card.linesLabel.font?.isFixedPitch == true)
        card.configure(HomeLinkPreview(kind: .workspace, title: "old", status: "Closed", statusTone: .danger))
        #expect(card.linesLabel.isHidden)
        #expect(card.placeRow.isHidden)
        #expect(card.icon.image != nil)
    }

    @Test func aFileShowsItsFirstLinesAndAMissingOneIsClosed() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("home-link-preview-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("REPORT.md")
        try "# Report\n\nPushed 3 commits.\n".write(to: file, atomically: true, encoding: .utf8)
        #expect(HomeLinkPreviewProvider.firstLines(file.path, folder: false) == ["# Report", "Pushed 3 commits."])
        #expect(HomeLinkPreviewProvider.firstLines(dir.path, folder: true) == ["REPORT.md"])
        #expect(HomeLinkPreviewProvider.firstLines(dir.appendingPathComponent("gone.md").path, folder: false) == nil)

        let services = AppServices(environment: AppEnvironment.current([:]))
        let provider = HomeLinkPreviewProvider(services: services)
        let quick = provider.preview(for: file, kind: .markdown)
        #expect(quick.title == "REPORT.md")
        let full = await provider.details(for: file, preview: quick)
        #expect(full.lines == ["# Report", "Pushed 3 commits."])
        let gone = dir.appendingPathComponent("gone.md")
        let missing = await provider.details(for: gone, preview: provider.preview(for: gone, kind: .markdown))
        #expect(missing.status == HomeLinkPreviewStrings.closed)
        withExtendedLifetime(services) {}
    }

    @Test func aWorkspaceTheAppDoesNotHaveIsClosed() {
        let services = AppServices(environment: AppEnvironment.current([:]))
        let provider = HomeLinkPreviewProvider(services: services)
        let url = URL(string: "cmux://workspace/ws_0123456789abcdef0123456789abcdef")!
        let preview = provider.preview(for: url, kind: .workspace)
        #expect(preview.status == HomeLinkPreviewStrings.closed)
        #expect(preview.statusTone == .danger)
        withExtendedLifetime(services) {}
    }

    @Test func aGitHubChipNamesItsRepository() {
        let services = AppServices(environment: AppEnvironment.current([:]))
        let provider = HomeLinkPreviewProvider(services: services)
        let preview = provider.preview(for: URL(string: "https://github.com/manaflow-ai/cmux/pull/22245")!, kind: .pullRequest)
        #expect(preview.title == "#22245")
        #expect(preview.place == "manaflow-ai/cmux")
        withExtendedLifetime(services) {}
    }
}
