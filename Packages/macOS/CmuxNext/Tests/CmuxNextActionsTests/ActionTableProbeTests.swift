import AppKit
@testable import CmuxNextActions
import Foundation
import Testing

/// Throwaway probe: which tables the module bundle ships per language, and whether an untabled
/// lookup of an `ActionCatalog.xcstrings` key resolves.
@Suite struct ActionTableProbeTests {
    @Test func probe() throws {
        var lines: [String] = []
        let bundle = Bundle.module
        lines.append("localizations: \(bundle.localizations.sorted())")
        for language in ["en", "ja"] {
            guard let dir = bundle.path(forResource: language, ofType: "lproj") else { lines.append("\(language): no lproj"); continue }
            let files = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
            lines.append("\(language).lproj: \(files.sorted())")
            for table in ["Localizable", "ActionCatalog"] {
                let path = (dir as NSString).appendingPathComponent("\(table).strings")
                let dict = NSDictionary(contentsOfFile: path)
                lines.append("\(language) \(table): \(dict?.count ?? -1) keys; action.openSettings=\(dict?["action.openSettings"] ?? "nil")")
            }
            if let sub = Bundle(path: dir) {
                lines.append("\(language) untabled: \(sub.localizedString(forKey: "action.openSettings", value: "MISSING", table: nil))")
                lines.append("\(language) ActionCatalog: \(sub.localizedString(forKey: "action.openSettings", value: "MISSING", table: "ActionCatalog"))")
            }
        }
        let out = ProcessInfo.processInfo.environment["FAST_CHECKS_OUT"] ?? NSTemporaryDirectory()
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("plans/cmux-next/probe.txt")
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        _ = out
        print(lines.joined(separator: "\n"))
    }
}
