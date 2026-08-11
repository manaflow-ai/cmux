import Foundation

struct BrowserLocalFileTestFixture {
    let root: URL
    let targetDirectory: URL
    let linkDirectory: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CmuxBrowserLocalFile-\(UUID().uuidString)", isDirectory: true)
        targetDirectory = root.appendingPathComponent("target", isDirectory: true)
        linkDirectory = root.appendingPathComponent("link", isDirectory: true)
        try FileManager.default.createDirectory(
            at: targetDirectory,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: linkDirectory,
            withIntermediateDirectories: true
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}
