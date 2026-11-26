public import Foundation

/// The action exports the repository checks in, written from the catalog: `action-catalog.json`
/// (`ActionCatalogDump`), `action-surfaces.json` (`ActionSurfaceExport`), the generated block of
/// `actions.md` (`ActionSurfaceReport`) and `links.json` (`DeepLinkExport`), all under `plans/cmux-next/`.
/// The Mac's parity tests and the Linux exporter (`cmux-next-action-exports`,
/// scripts/cmux-next/regenerate-action-exports-linux.sh) both call these, so either writes the same bytes.
public struct ActionExports {
    public init() {}
    /// The files `write(repository:)` rewrites, relative to the repository root.
    public nonisolated static let files = [
        "plans/cmux-next/action-catalog.json", "plans/cmux-next/action-surfaces.json", "plans/cmux-next/actions.md",
        "plans/cmux-next/links.json",
    ]

    /// What the exports list: the Rust catalog's descriptors in its order, English, with their plain
    /// titles, not the palette's "Debug: <name>" ones.
    public static var exportedCatalog: [ActionDescriptor] { RustActionCatalog.shared.descriptors }

    /// `action-catalog.json`'s text: the English catalog's dump.
    public static func catalogJSON() throws -> String {
        try ActionCatalogDump.json(RustActionCatalog.load(language: "en"))
    }

    /// `action-surfaces.json`'s text, with each title's localization key from `titles`.
    public static func surfacesJSON(titles: ActionTitleCatalog) -> String {
        ActionSurfaceExport.json(exportedCatalog, titles: titles)
    }

    /// `actions.md` with its generated block replaced, or nil when `text` has no generated block.
    public static func report(replacingBlockIn text: String) -> String? {
        guard let start = text.range(of: ActionSurfaceReport.begin), let end = text.range(of: ActionSurfaceReport.end),
              start.lowerBound <= end.lowerBound
        else { return nil }
        return String(text[..<start.lowerBound]) + ActionSurfaceReport(exportedCatalog, menus: .shared).markdown + String(text[end.upperBound...])
    }

    /// `links.json`'s text. Its schemes are each build's (Rust's cloud_config_from_selection, which the Mac app
    /// links): the committed ones (`stored`) stand, and LinkExportTests on the Mac checks them against the code.
    /// Everything else in the file is DeepLink's.
    public static func linksJSON(stored: String) throws -> String {
        try DeepLinkExport(schemesOf: Data(stored.utf8)).json()
    }

    /// The string catalogs (`*.xcstrings` file names and bytes) of CmuxNextActions, as one title catalog.
    public nonisolated static func titleCatalog(files: [(name: String, data: Data)]) throws -> ActionTitleCatalog {
        try ActionTitleCatalog(catalogs: files.sorted { $0.name < $1.name }.map {
            (URL(fileURLWithPath: $0.name).deletingPathExtension().lastPathComponent, $0.data)
        })
    }

    /// Each export's text, by repository path, from the committed ones (`stored`, by the same paths; links.json's
    /// schemes and actions.md's prose come from them) and the module's title catalog. The caller reads and writes
    /// the files (the Linux exporter, the Mac's parity tests).
    public static func render(stored: [String: String], titles: ActionTitleCatalog) throws -> [String: String] {
        guard let report = report(replacingBlockIn: stored["plans/cmux-next/actions.md"] ?? "") else {
            throw CocoaError(.fileReadCorruptFile, userInfo: [NSFilePathErrorKey: "plans/cmux-next/actions.md"])
        }
        return [
            "plans/cmux-next/action-catalog.json": try catalogJSON(),
            "plans/cmux-next/action-surfaces.json": surfacesJSON(titles: titles),
            "plans/cmux-next/actions.md": report,
            "plans/cmux-next/links.json": try linksJSON(stored: stored["plans/cmux-next/links.json"] ?? ""),
        ]
    }
}
