import CmuxNextActions
import Foundation

// cmux-next-action-exports [REPOSITORY]: rewrites plans/cmux-next's action exports (action-catalog.json,
// action-surfaces.json, actions.md's generated block and links.json) from the catalog, and prints each
// file whose bytes changed. It is the Linux build of the exports (scripts/cmux-next/regenerate-action-exports-linux.sh),
// a command-line tool with no UI; the Mac's parity tests write and check the same files through the same code
// (ActionExports.render).
let root = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? FileManager.default.currentDirectoryPath)
do {
    var stored: [String: String] = [:]
    for file in ActionExports.files {
        stored[file] = try? String(contentsOf: root.appending(path: file, directoryHint: .notDirectory), encoding: .utf8)
    }
    // Resolved first: Linux's Foundation lists nothing through a symlinked directory.
    let sources = root.appending(path: "Packages/macOS/CmuxNext/Sources/CmuxNextActions", directoryHint: .isDirectory)
        .resolvingSymlinksInPath()
    let catalogs = try FileManager.default.contentsOfDirectory(at: sources, includingPropertiesForKeys: nil)
        .filter { $0.pathExtension == "xcstrings" }
        .map { (name: $0.lastPathComponent, data: try Data(contentsOf: $0)) }
    let outputs = try ActionExports.render(stored: stored, titles: try ActionExports.titleCatalog(files: catalogs))
    for file in ActionExports.files where outputs[file] != stored[file] {
        try outputs[file, default: ""].write(to: root.appending(path: file, directoryHint: .notDirectory), atomically: true, encoding: .utf8)
        print("regenerated: \(file)")
    }
} catch {
    FileHandle.standardError.write(Data("cmux-next-action-exports: \(error)\n".utf8))
    exit(1)
}
