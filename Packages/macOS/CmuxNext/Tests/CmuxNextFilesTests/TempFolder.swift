import Foundation

/// A fresh folder under the system temp directory, removed on deinit. Every
/// test that writes files writes only here.
final class TempFolder {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-files-tests-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: url) }

    @discardableResult
    func file(_ name: String, bytes: Int = 0, in sub: String? = nil) throws -> URL {
        let folder = sub.map { url.appendingPathComponent($0) } ?? url
        let target = folder.appendingPathComponent(name)
        try Data(repeating: 0x61, count: bytes).write(to: target)
        return target
    }

    @discardableResult
    func folder(_ name: String) throws -> URL {
        let target = url.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        return target
    }

    func names() -> Set<String> {
        Set((try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? [])
    }
}
