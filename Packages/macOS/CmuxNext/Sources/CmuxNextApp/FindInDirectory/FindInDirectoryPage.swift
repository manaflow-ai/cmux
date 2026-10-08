import AppKit
import CmuxNextActions
import CmuxNextPalette

/// The matches of one Find in Directory search as a palette page: one row
/// per matching line, filtered by the palette's matcher on the line, the
/// file path and the line number.
@MainActor
enum FindInDirectoryPage {
    /// What Insert Path sends text to: the terminal the search ran from.
    typealias Insert = @MainActor (String) -> Void

    static func page(query: String, root: String, rg: URL, insert: @escaping Insert) -> PalettePageSpec {
        let provider = AsyncPaletteProvider(id: "findInDirectory.results") {
            items(for: await RipgrepSearch.run(rg, query: query, root: root), insert: insert)
        }
        return PalettePageSpec(id: "findInDirectory.results", title: query,
                               placeholder: (root as NSString).abbreviatingWithTildeInPath,
                               symbol: "folder.badge.magnifyingglass", providers: [provider])
    }

    static func items(for outcome: RipgrepSearch.Outcome, insert: @escaping Insert) -> [PaletteItem] {
        switch outcome {
        case .failed(let status):
            return [notice(FindInDirectoryStrings.ripgrepExited(status))]
        case .matches(let matches, let limited):
            let rows = matches.map { item(for: $0, insert: insert) }
            return limited ? rows + [notice(FindInDirectoryStrings.limited(RipgrepSearch.limit))] : rows
        }
    }

    private static func notice(_ text: String) -> PaletteItem {
        PaletteItem(id: "findInDirectory.notice", title: text, symbol: "info.circle", isEnabled: false, primary:
            PaletteCommand(id: "none", title: text, effect: .performKeepingOpen {}), rankBias: -1_000)
    }

    private static func item(for match: RipgrepMatch, insert: @escaping Insert) -> PaletteItem {
        let url = URL(fileURLWithPath: match.path)
        let location = "\(match.relativePath):\(match.line)"
        let secondary = [
            PaletteCommand(id: "reveal", title: FindInDirectoryStrings.revealInFinder, symbol: "folder",
                           effect: .perform { NSWorkspace.shared.activateFileViewerSelecting([url]) }),
            PaletteCommand(id: "copyPath", title: FindInDirectoryStrings.copyPath, symbol: "doc.on.doc",
                           effect: .perform { copy(match.path) }),
            PaletteCommand(id: "copyRelativePath", title: FindInDirectoryStrings.copyRelativePath, symbol: "doc.on.doc",
                           effect: .perform { copy(match.relativePath) }),
            PaletteCommand(id: "insertPath", title: FindInDirectoryStrings.insertPath, symbol: "text.insert",
                           effect: .perform { insert(TerminalHandlers.shellQuoted(match.path)) }),
        ]
        return PaletteItem(
            id: "\(match.path):\(match.line):\(match.column)", title: match.preview, subtitle: location,
            symbol: "doc.text", keywords: [location],
            primary: PaletteCommand(id: "open", title: FindInDirectoryStrings.open, symbol: "return",
                                    effect: .perform { NSWorkspace.shared.open(url) }),
            secondary: secondary)
    }

    private static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

enum FindInDirectoryStrings {
    private static func text(_ key: StaticString, _ value: String.LocalizationValue) -> String {
        String(localized: key, defaultValue: value, table: "FindInDirectory", bundle: .module)
    }

    static var open: String { text("findInDirectory.open", "Open in Default Editor") }
    static var revealInFinder: String { text("findInDirectory.revealInFinder", "Reveal in Finder") }
    static var copyPath: String { text("findInDirectory.copyPath", "Copy Path") }
    static var copyRelativePath: String { text("findInDirectory.copyRelativePath", "Copy Relative Path") }
    static var insertPath: String { text("findInDirectory.insertPath", "Insert Path") }
    static var localOnly: String { text("findInDirectory.localOnly", "Local folders only") }
    static var ripgrepMissing: String { text("findInDirectory.ripgrepMissing", "ripgrep (rg) is not installed or is not on PATH.") }
    static func ripgrepExited(_ status: Int32) -> String {
        String(format: text("findInDirectory.ripgrepExited", "rg exited with status %lld"), Int(status))
    }
    static func limited(_ count: Int) -> String {
        String(format: text("findInDirectory.limited", "First %lld matches"), count)
    }
}
