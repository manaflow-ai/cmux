import AppKit
@testable import CmuxNextActions
import Foundation
import ObjectiveC
import Testing

/// The catalog dump (`ActionCatalogDumpTests.json()`) with every localized string marked with
/// the string table and key it was read from, written to
/// `plans/cmux-next/action-catalog-keys.json` when that file is the placeholder `{}`. Two keys
/// can share an English value and differ in another language, so the Rust catalog takes each
/// string's key from here instead of guessing it from the English.
///
/// Run it alone, in its own process (`--filter ActionCatalogKeyDumpTests`): it swaps
/// `Bundle.localizedString(forKey:value:table:)` before the catalog is first built.
@MainActor
@Suite struct ActionCatalogKeyDumpTests {
    nonisolated static let url = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("plans/cmux-next/action-catalog-keys.json")

    nonisolated static var wantsDump: Bool {
        (try? String(contentsOf: url, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) == "{}"
    }

    @Test(.enabled(if: wantsDump)) func keyDump() throws {
        Bundle.markLocalizedStrings()
        let text = try ActionCatalogDumpTests.json()
        try text.write(to: Self.url, atomically: true, encoding: .utf8)
        #expect(text.contains("\u{E001}action.newTab.default\u{E002}"), "String(localized:) did not go through the swapped lookup")
    }
}

extension Bundle {
    /// Swaps the string lookups for ones that prefix each result with `U+E000 table U+E001 key U+E002`.
    static func markLocalizedStrings() {
        let pairs: [(Selector, Selector)] = [
            (#selector(Bundle.localizedString(forKey:value:table:)), #selector(Bundle.cmuxMarked(forKey:value:table:))),
        ]
        for (original, marked) in pairs {
            guard let a = class_getInstanceMethod(Bundle.self, original), let b = class_getInstanceMethod(Bundle.self, marked) else { continue }
            method_exchangeImplementations(a, b)
        }
    }

    @objc dynamic func cmuxMarked(forKey key: String, value: String?, table: String?) -> String {
        // After the exchange this calls the original lookup.
        let resolved = cmuxMarked(forKey: key, value: value, table: table)
        return "\u{E000}\(table ?? "Localizable")\u{E001}\(key)\u{E002}\(resolved)"
    }
}
