import CmuxNextCompat
public import Foundation

extension SettingsSchemaExport {
    /// Read the source catalog shards, independently of SwiftPM's generated resource bundle.
    public nonisolated func catalogKeys(directory: URL) throws -> Set<String> {
        var keys = Set<String>()
        for name in try FileManager.checked.contentsOfDirectory(atPath: directory.path).sorted()
            where name.hasSuffix(".xcstrings")
        {
            keys.formUnion(try catalogKeys(xcstrings: Data(blockingContentsOf: directory.appending(path: name))))
        }
        return keys
    }
}
