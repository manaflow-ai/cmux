// Writes the settings exports listed in scripts/cmux-next/settings-exports.txt under OUT_DIR, from the
// repository at REPO_ROOT (it reads Localizable.xcstrings). The Mac tests
// (ManagedPreferencesManifestTests, SettingsSchemaExportTests) compare the same bytes.
import CmuxNextSettings
import Foundation

let arguments = CommandLine.arguments
guard arguments.count == 3 else {
    FileHandle.standardError.write(Data("usage: cmux-next-settings-exports OUT_DIR REPO_ROOT\n".utf8))
    exit(2)
}
let out = URL(fileURLWithPath: arguments[1], isDirectory: true)
let root = URL(fileURLWithPath: arguments[2], isDirectory: true)
do {
    let catalog = try SettingsSchemaExport().catalogKeys(
        xcstrings: Data(contentsOf: root.appending(path: "Packages/macOS/CmuxNext/Sources/CmuxNextSettings/Localizable.xcstrings")))
    var files: [(String, Data)] = try ManagedPreferencesManifest.exportFiles().map { ("docs/mdm/\($0.name)", $0.data) }
    files.append(("schemas/settings/settings-schema.json", Data(try SettingsSchemaExport().json(catalog: catalog).utf8)))
    for (path, data) in files {
        let url = out.appending(path: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    }
} catch {
    FileHandle.standardError.write(Data("cmux-next-settings-exports: \(error)\n".utf8))
    exit(1)
}
