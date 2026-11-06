import AppKit
@testable import CmuxNextActions
import Foundation
import Testing

/// The catalog dump (`ActionCatalogDumpTests.json()`) as the app resolves it in each of its
/// languages, merged into `plans/cmux-next/action-catalog-locales.json` while that file is the
/// placeholder `{}` or a partial merge. Each test must run in its own process (one
/// `--filter ActionCatalogLocaleDumpTests.locale_<language>` per run): it sets the process's
/// language before the catalog is first built. The Rust catalog's translations are checked
/// against these.
@MainActor
@Suite struct ActionCatalogLocaleDumpTests {
    nonisolated static let url = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("plans/cmux-next/action-catalog-locales.json")

    nonisolated static var wanted: Bool {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return false }
        return text.trimmingCharacters(in: .whitespacesAndNewlines) == "{}" || text.hasPrefix("{\"partial\"")
    }

    static func dump(_ language: String) throws {
        UserDefaults.standard.setVolatileDomain(["AppleLanguages": [language]], forName: UserDefaults.argumentDomain)
        let text = try ActionCatalogDumpTests.json()
        let data = try Data(contentsOf: url)
        var merged = (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        var locales = merged["locales"] as? [String: Any] ?? [:]
        locales[language] = try JSONSerialization.jsonObject(with: Data(text.utf8))
        merged["locales"] = locales
        merged["partial"] = true
        let out = try JSONSerialization.data(withJSONObject: merged, options: [.sortedKeys])
        try out.write(to: url, options: .atomic)
        #expect(ActionCatalog.all.first { $0.id == "newSurface" }?.title != "New Terminal Tab", "the catalog did not take \(language)")
    }

    @Test(.enabled(if: wanted)) func locale_ja() throws { try Self.dump("ja") }
    @Test(.enabled(if: wanted)) func locale_ar() throws { try Self.dump("ar") }
    @Test(.enabled(if: wanted)) func locale_bs() throws { try Self.dump("bs") }
    @Test(.enabled(if: wanted)) func locale_da() throws { try Self.dump("da") }
    @Test(.enabled(if: wanted)) func locale_de() throws { try Self.dump("de") }
    @Test(.enabled(if: wanted)) func locale_es() throws { try Self.dump("es") }
    @Test(.enabled(if: wanted)) func locale_fr() throws { try Self.dump("fr") }
    @Test(.enabled(if: wanted)) func locale_it() throws { try Self.dump("it") }
    @Test(.enabled(if: wanted)) func locale_km() throws { try Self.dump("km") }
    @Test(.enabled(if: wanted)) func locale_ko() throws { try Self.dump("ko") }
    @Test(.enabled(if: wanted)) func locale_nb() throws { try Self.dump("nb") }
    @Test(.enabled(if: wanted)) func locale_pl() throws { try Self.dump("pl") }
    @Test(.enabled(if: wanted)) func locale_pt_BR() throws { try Self.dump("pt-BR") }
    @Test(.enabled(if: wanted)) func locale_ru() throws { try Self.dump("ru") }
    @Test(.enabled(if: wanted)) func locale_th() throws { try Self.dump("th") }
    @Test(.enabled(if: wanted)) func locale_tr() throws { try Self.dump("tr") }
    @Test(.enabled(if: wanted)) func locale_uk() throws { try Self.dump("uk") }
    @Test(.enabled(if: wanted)) func locale_vi() throws { try Self.dump("vi") }
    @Test(.enabled(if: wanted)) func locale_zh_Hans() throws { try Self.dump("zh-Hans") }
    @Test(.enabled(if: wanted)) func locale_zh_Hant() throws { try Self.dump("zh-Hant") }
}
