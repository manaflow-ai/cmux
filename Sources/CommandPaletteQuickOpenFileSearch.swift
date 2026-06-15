import AppKit
import CmuxCommandPalette
import Foundation
import UniformTypeIdentifiers

extension ContentView {
    nonisolated static func commandPaletteFileSearchMatchingTerm(
        _ matchingQuery: String,
        workspaceRoot: String? = nil
    ) -> String {
        CommandPaletteQuickOpenFileSearch.matchingTerm(matchingQuery, workspaceRoot: workspaceRoot)
    }

    static func commandPaletteFileSearchFingerprint(query: String) -> Int {
        CommandPaletteQuickOpenFileSearch.fingerprint(query: query)
    }

    static func commandPaletteFileSearchDedupFingerprint(
        query: String,
        isCrossDirectory: Bool,
        workspaceRoot: String? = nil
    ) -> Int? {
        guard isCrossDirectory,
              commandPaletteListScope(for: query) == .fileSearch else {
            return nil
        }
        return CommandPaletteQuickOpenFileSearch.crossDirectoryDedupFingerprint(
            query: query,
            workspaceRoot: workspaceRoot
        )
    }

    static func commandPaletteFileSearchResolve(
        matchingQuery: String,
        workspaceRoot: String?
    ) -> CommandPaletteQuickOpenFileSearch.ResolvedPath {
        CommandPaletteQuickOpenFileSearch.resolve(matchingQuery: matchingQuery, workspaceRoot: workspaceRoot)
    }

    static func resolveLongestExistingDirectory(_ path: String) -> (existingDir: String?, remainder: String) {
        CommandPaletteQuickOpenFileSearch.resolveLongestExistingDirectory(path)
    }

    static func commandPaletteFileSearchPathForDirectory(
        _ url: URL,
        rootDir: String,
        usePathPrefix: Bool = true
    ) -> String {
        CommandPaletteQuickOpenFileSearch.pathForDirectory(
            url,
            rootDir: rootDir,
            usePathPrefix: usePathPrefix
        )
    }

    /// Open a file for viewing/editing, avoiding accidental execution of scripts
    /// or binaries in a terminal.
    static func openFileInDefaultEditor(_ url: URL) {
        Task(priority: .userInitiated) {
            let action = CommandPaletteQuickOpenFileSearch.openAction(for: url)
            await Self.performQuickOpenFileOpenAction(action)
        }
    }

    nonisolated static func quickOpenFileOpenAction(
        for url: URL
    ) async -> CommandPaletteQuickOpenFileOpenAction {
        CommandPaletteQuickOpenFileSearch.openAction(for: url)
    }

    @MainActor
    static func performQuickOpenFileOpenAction(_ action: CommandPaletteQuickOpenFileOpenAction) {
        switch action {
        case .open(let url):
            NSWorkspace.shared.open(url)
        case .reveal(let url):
            NSWorkspace.shared.activateFileViewerSelecting([url])
        case .textEditor(let url):
            guard let editorURL = NSWorkspace.shared.urlForApplication(toOpen: UTType.plainText) else {
                NSWorkspace.shared.open(url)
                return
            }
            NSWorkspace.shared.open(
                [url],
                withApplicationAt: editorURL,
                configuration: NSWorkspace.OpenConfiguration()
            )
        }
    }

    nonisolated static func isDirectory(_ url: URL) -> Bool {
        CommandPaletteQuickOpenFileSearch.isDirectory(url)
    }

    nonisolated static func listFilesInDirectory(_ dir: String, maxCount: Int) -> [URL] {
        CommandPaletteQuickOpenFileSearch.listFiles(inDirectory: dir, maxCount: maxCount)
    }

    nonisolated static func shouldSkipDirectoryForQuickOpen(_ name: String) -> Bool {
        CommandPaletteQuickOpenFileSearch.shouldSkipDirectory(name)
    }

    nonisolated static func searchCrossDirectory(
        query: String,
        rootDir: String
    ) async -> [CommandPaletteQuickOpenScoredFile] {
        await CommandPaletteQuickOpenFileSearch.searchCrossDirectory(query: query, rootDir: rootDir)
    }

    nonisolated static func fileSearchCrossDirectoryFuzzyScore(query: String, candidate: String) -> Int? {
        CommandPaletteQuickOpenFileSearch.fuzzyScore(query: query, candidate: candidate)
    }

    nonisolated static func fileSearchCrossDirectoryFuzzyMatch(
        query: String,
        candidate: String
    ) -> (score: Int, indices: Set<Int>)? {
        CommandPaletteQuickOpenFileSearch.fuzzyMatch(query: query, candidate: candidate)
    }

    nonisolated static func quickOpenRelativePath(url: URL, rootDir: String) -> String {
        CommandPaletteQuickOpenFileSearch.relativePath(url: url, rootDir: rootDir)
    }
}
