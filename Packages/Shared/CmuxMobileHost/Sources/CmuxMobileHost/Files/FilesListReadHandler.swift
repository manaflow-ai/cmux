import CmuxMobileWire
import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// `read files.list`: one page of a directory in scope. Never follows a
/// symlink while listing and omits denied names.
public struct FilesListReadHandler: MobileReadHandler {
    let configuration: MobileFilesConfiguration
    let roots: any MobileFileRootsProvider

    init(configuration: MobileFilesConfiguration, roots: any MobileFileRootsProvider) {
        self.configuration = configuration
        self.roots = roots
    }

    public func read(_ frame: ReadFrame, principal: MobileDevicePrincipal) async throws -> JSONValue {
        guard let params = try? frame.params.decode(as: FilesListParams.self) else {
            throw MobileDaemonError.filesInvalid("bad files.list params")
        }
        let policy = MobileFilePolicy(configuration: configuration, roots: await roots.roots(for: principal))
        let resolved = try policy.resolveExisting(params.path)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resolved.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw MobileDaemonError.filesInvalid("not a directory")
        }
        let limit = min(max(1, params.limit ?? configuration.listDefaultLimit), configuration.listMaxLimit)
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: resolved.path)) ?? [])
            .filter { !MobileFilePolicy.deniedNames.contains($0) }
            .filter { name in params.after.map { name > $0 } ?? true }
            .sorted()
        var entries: [FilesListEntry] = []
        for name in names.prefix(limit) {
            var info = stat()
            guard lstat(resolved.path + "/" + name, &info) == 0 else { continue }
            let kind: FilesListEntry.Kind
            switch info.st_mode & S_IFMT {
            case S_IFDIR: kind = .dir
            case S_IFLNK: kind = .symlink
            case S_IFREG: kind = .file
            default: continue
            }
            let modified = Int64(info.st_mtimespec.tv_sec) * 1000 + Int64(info.st_mtimespec.tv_nsec) / 1_000_000
            entries.append(FilesListEntry(name: name, kind: kind, size: kind == .file ? UInt64(info.st_size) : 0,
                                          modifiedAt: modified))
        }
        let next = names.count > limit ? names[limit - 1] : nil
        return try JSONValue(encoding: FilesListResult(entries: entries, next: next))
    }
}
