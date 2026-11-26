import AppKit
@testable import CmuxNextActions
import Foundation
import Testing

/// The catalog the app decodes from Rust (`RustActionCatalog`, from
/// cmux-tui/crates/cmux-action-catalog) is the Swift catalog it replaced, field for field:
/// every field of every descriptor, the key binding defaults (each `when` clause parsed from
/// its text), the palette tables, categories and menu folders, dumped the way the Swift
/// catalog was dumped into `plans/cmux-next/action-catalog.json` before its literals were
/// deleted. Rust's own test (`tests/swift_parity.rs`) compares its JSON with the same file.
///
/// The dump reflects each value (`Mirror`), so a stored field added to a descriptor, an
/// argument or a placement is dumped without a change here. Strings are English.
@MainActor
@Suite struct ActionCatalogDumpTests {
    nonisolated static let url = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("plans/cmux-next/action-catalog.json")

    /// The English catalog decodes to the Swift catalog's dump, byte for byte. The dump is a Debug
    /// build's, so a Release test build, which drops the Debug-only entries, does not compare it.
    #if DEBUG
    @Test func decodedCatalogEqualsTheSwiftDump() throws {
        let english = RustActionCatalog.load(language: "en")
        let current = try Self.json(english)
        if ProcessInfo.processInfo.environment["CMUX_UPDATE_ACTION_SURFACES"] == "1" {
            try current.write(to: Self.url, atomically: true, encoding: .utf8)
        }
        let stored = try String(contentsOf: Self.url, encoding: .utf8)
        // Compared by its first difference: the whole dump is too long for a test log.
        #expect(Self.firstDifference(stored, current) == "none", "the decoded catalog differs from action-catalog.json")
    }
    #endif

    /// The first line where two dumps part, with a few lines around it from each.
    nonisolated static func firstDifference(_ stored: String, _ current: String) -> String {
        let old = stored.components(separatedBy: "\n"), new = current.components(separatedBy: "\n")
        guard let line = zip(old, new).enumerated().first(where: { $0.element.0 != $0.element.1 })?.offset
                ?? (old.count == new.count ? nil : min(old.count, new.count))
        else { return "none" }
        let window = { (lines: [String]) in lines[max(0, line - 12)..<min(lines.count, line + 4)].joined(separator: "\n") }
        return "line \(line + 1) (stored \(old.count) lines, decoded \(new.count))\n--- stored\n\(window(old))\n--- decoded\n\(window(new))"
    }

    /// The dump never falls back to a value's description: every leaf is a known kind.
    @Test func dumpHasNoOpaqueValues() throws {
        let text = try Self.json(RustActionCatalog.load(language: "en"))
        #expect(!text.contains("\"<opaque"), "a value the dump cannot reflect")
    }

    /// A Release build drops what only a Debug build has; a Debug build keeps it.
    @Test func debugBuildEntriesAreDroppedOnlyOutsideDebug() throws {
        let rows: [[String: Any]] = [
            ["id": "a"], ["id": "b"],
            ["id": "c", "arguments": [["name": "viewer", "kind": ["enumeration": [["value": "rd"], ["value": "native"]]]]]],
        ]
        let table: [String: Any] = ["actions": ["b"], "cases": [["action": "c", "argument": "viewer", "value": "native"]]]
        let kept = RustActionCatalog.withoutDebugBuildEntries(rows, table)
        #expect(kept.compactMap { $0["id"] as? String } == ["a", "c"])
        let viewer = (kept.last?["arguments"] as? [[String: Any]])?.first?["kind"] as? [String: Any]
        #expect((viewer?["enumeration"] as? [[String: Any]])?.compactMap { $0["value"] as? String } == ["rd"])
        #if DEBUG
        #expect(ActionCatalog.all.contains { $0.id == "home.agentMessagePlayground" }, "a Debug test build keeps its playgrounds")
        #else
        #expect(!ActionCatalog.all.contains { $0.id == "home.agentMessagePlayground" }, "a Release test build drops the playgrounds")
        #endif
    }

    /// Japanese titles come back translated, from each title's own string table.
    @Test func japaneseTitlesAreTranslated() {
        let japanese = RustActionCatalog.load(language: "ja-JP")
        let english = RustActionCatalog.load(language: "en")
        let title = { (catalog: RustActionCatalog) in catalog.descriptors.first { $0.id == "newSurface" }?.title }
        #expect(title(english) == "New Terminal Tab")
        #expect(title(japanese) != nil && title(japanese) != title(english))
        #expect(japanese.descriptors.count == english.descriptors.count)
    }

    static func json(_ catalog: RustActionCatalog) throws -> String { try ActionCatalogDump.json(catalog) }
}
