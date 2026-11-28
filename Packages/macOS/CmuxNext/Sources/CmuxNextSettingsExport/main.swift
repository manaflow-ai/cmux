import CmuxNextCompat
import CmuxNextSettings
import Foundation

// Writes the settings exports from CmuxNextSettings alone: schemas/settings/settings-schema.json
// (what the daemon embeds and validates writes against) and docs/mdm/* (the MDM manifests).
// scripts/cmux-next/regenerate-settings-exports.sh builds and runs it instead of the package's test
// bundle, so a test target elsewhere in CmuxNext that does not compile can no longer hold the exports
// back (2026-11-25: CmuxNextAppTests compile errors failed every base autofix export for hours, and
// the daemon called presence.live an unknown key). SettingsSchemaExportTests and
// ManagedPreferencesManifestTests still check the same bytes, through the same calls.
//
// Usage: CmuxNextSettingsExport REPO_ROOT

let arguments = CommandLine.arguments
guard arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: CmuxNextSettingsExport REPO_ROOT\n".utf8))
    exit(64)
}
let root = URL(fileURLWithPath: arguments[1], isDirectory: true)
do {
    let export = SettingsSchemaExport()
    let catalog = try export.catalogKeys(xcstrings: Data(blockingContentsOf: root.appending(
        path: "Packages/macOS/CmuxNext/Sources/CmuxNextSettings/Localizable.xcstrings")))
    let schema = root.appending(path: "schemas/settings/settings-schema.json")
    try FileManager.checked.createDirectory(at: schema.deletingLastPathComponent(), withIntermediateDirectories: true)
    try export.json(catalog: catalog).blockingWrite(to: schema, atomically: true, encoding: .utf8)
    let docs = root.appending(path: "docs/mdm")
    try FileManager.checked.createDirectory(at: docs, withIntermediateDirectories: true)
    for (name, data) in try ManagedPreferencesManifest.exportFiles() {
        try data.blockingWrite(to: docs.appending(path: name))
    }
} catch {
    FileHandle.standardError.write(Data("CmuxNextSettingsExport: \(error)\n".utf8))
    exit(1)
}
