import Foundation

// SAFETY: FileManager's operations are thread-safe when no delegate is set;
// this value never exposes or configures a delegate on its private instance.
struct SimulatorPrivacyFileSystem: @unchecked Sendable {
    private let manager: FileManager

    init(manager: FileManager = FileManager()) {
        self.manager = manager
    }

    var temporaryDirectory: URL { manager.temporaryDirectory }

    func userLibraryDirectory() -> URL? {
        manager.urls(for: .libraryDirectory, in: .userDomainMask).first
    }

    func isExecutableFile(atPath path: String) -> Bool {
        manager.isExecutableFile(atPath: path)
    }

    func isReadableFile(atPath path: String) -> Bool {
        manager.isReadableFile(atPath: path)
    }

    func fileExists(atPath path: String) -> Bool {
        manager.fileExists(atPath: path)
    }

    func contents(atPath path: String) -> Data? {
        manager.contents(atPath: path)
    }

    func createDirectory(at url: URL, attributes: [FileAttributeKey: Any]? = nil) throws {
        try manager.createDirectory(
            at: url,
            withIntermediateDirectories: true,
            attributes: attributes
        )
    }

    func removeItem(at url: URL) throws {
        try manager.removeItem(at: url)
    }

    func replaceItem(at destination: URL, with source: URL) throws {
        _ = try manager.replaceItemAt(destination, withItemAt: source)
    }

    func setAttributes(_ attributes: [FileAttributeKey: Any], atPath path: String) throws {
        try manager.setAttributes(attributes, ofItemAtPath: path)
    }
}
