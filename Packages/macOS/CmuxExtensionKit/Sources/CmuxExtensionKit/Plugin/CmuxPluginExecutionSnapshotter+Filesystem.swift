import Darwin
import Foundation

extension CmuxPluginExecutionSnapshotter {

    func openEntrypoint(
        at url: URL,
        interpreterDescriptor: Int32?,
        interpreterURL: URL?
    ) throws -> (
        descriptor: Int32,
        execution: CmuxPluginEntrypointExecution,
        interpreterDescriptor: Int32?,
        interpreterURL: URL?
    ) {
        let executableDescriptor = Darwin.open(url.path, O_EXEC)
        guard executableDescriptor >= 0 else {
            throw CmuxPluginExecutionSnapshotError.entrypointDescriptorFailed
        }

        let readableDescriptor = Darwin.open(url.path, O_RDONLY)
        guard readableDescriptor >= 0 else {
            Darwin.close(executableDescriptor)
            throw CmuxPluginExecutionSnapshotError.entrypointDescriptorFailed
        }

        do {
            if let interpreterArguments = try shebangArguments(from: readableDescriptor) {
                guard interpreterDescriptor != nil, interpreterURL != nil else {
                    throw CmuxPluginExecutionSnapshotError.invalidInterpreter
                }
                Darwin.close(executableDescriptor)
                return (
                    readableDescriptor,
                    .interpreter(Array(interpreterArguments.dropFirst())),
                    interpreterDescriptor,
                    interpreterURL
                )
            }
            guard interpreterDescriptor == nil else {
                throw CmuxPluginExecutionSnapshotError.invalidInterpreter
            }
            Darwin.close(readableDescriptor)
            return (executableDescriptor, .executable, nil, nil)
        } catch {
            Darwin.close(executableDescriptor)
            Darwin.close(readableDescriptor)
            throw error
        }
    }

    func openPinnedFiles(at root: URL) throws -> [String: Int32] {
        let root = canonicalURL(root)
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey],
            options: []
        ) else {
            throw CmuxPluginExecutionSnapshotError.validationFailed
        }
        var descriptors: [String: Int32] = [:]
        var entryCount = 0
        do {
            for case let url as URL in enumerator {
                guard entryCount < CmuxPluginArtifactFingerprinter.maximumArtifactEntries else {
                    throw CmuxPluginExecutionSnapshotError.validationFailed
                }
                entryCount += 1
                let values = try url.resourceValues(forKeys: [
                    .isDirectoryKey,
                    .isRegularFileKey,
                    .isSymbolicLinkKey,
                ])
                guard values.isSymbolicLink != true else {
                    throw CmuxPluginExecutionSnapshotError.validationFailed
                }
                guard values.isDirectory != true else { continue }
                guard values.isRegularFile == true,
                      url.path.hasPrefix(root.path + "/") else {
                    throw CmuxPluginExecutionSnapshotError.validationFailed
                }
                guard descriptors.count < CmuxPluginArtifactFingerprinter.maximumArtifactFiles else {
                    throw CmuxPluginExecutionSnapshotError.validationFailed
                }
                let descriptor = Darwin.open(
                    url.path,
                    O_RDONLY | O_NOFOLLOW | O_CLOEXEC
                )
                guard descriptor >= 0 else {
                    throw CmuxPluginExecutionSnapshotError.entrypointDescriptorFailed
                }
                let relativePath = String(url.path.dropFirst(root.path.count + 1))
                descriptors[relativePath] = descriptor
            }
            return descriptors
        } catch {
            descriptors.values.forEach { Darwin.close($0) }
            throw error
        }
    }

    func shebangArguments(from descriptor: Int32) throws -> [String]? {
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        let prefix: Data
        do {
            prefix = try handle.read(upToCount: 4096) ?? Data()
            try handle.seek(toOffset: 0)
        } catch {
            throw CmuxPluginExecutionSnapshotError.entrypointDescriptorFailed
        }

        let shebang: CmuxPluginShebang?
        do {
            shebang = try CmuxPluginShebang.parse(prefix: prefix)
        } catch {
            throw CmuxPluginExecutionSnapshotError.invalidInterpreter
        }
        guard let shebang else { return nil }
        return [shebang.interpreterPath] + shebang.arguments
    }

    func closeEntrypointDescriptor(_ descriptor: Int32, clearImmutable: Bool = true) {
        guard descriptor >= 0, openEntrypointDescriptors.remove(descriptor) != nil else { return }
        if clearImmutable {
            _ = Darwin.fchflags(descriptor, UInt32(0))
        }
        Darwin.close(descriptor)
    }

    func sealSnapshot(at stagingRoot: URL) throws {
        guard let enumerator = fileManager.enumerator(
            at: stagingRoot,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey],
            options: []
        ) else {
            throw CmuxPluginExecutionSnapshotError.validationFailed
        }

        var directories: [URL] = []
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [
                .isDirectoryKey,
                .isRegularFileKey,
                .isSymbolicLinkKey,
            ])
            guard values.isSymbolicLink != true else {
                throw CmuxPluginExecutionSnapshotError.validationFailed
            }
            if values.isDirectory == true {
                directories.append(url)
            } else if values.isRegularFile == true {
                try sealFile(at: url)
            } else {
                throw CmuxPluginExecutionSnapshotError.validationFailed
            }
        }

        // Seal children before parents so cleanup can reverse the operation
        // without attempting to mutate an immutable directory.
        for directory in directories.sorted(by: { depth(of: $0) > depth(of: $1) }) {
            try sealFile(at: directory, isDirectory: true)
        }
        try sealFile(at: stagingRoot, isDirectory: true)
    }

    func sealFile(at url: URL, isDirectory: Bool = false) throws {
        let flags = O_RDONLY | O_NOFOLLOW | (isDirectory ? O_DIRECTORY : 0)
        let descriptor = Darwin.open(url.path, flags)
        guard descriptor >= 0 else {
            throw CmuxPluginExecutionSnapshotError.entrypointDescriptorFailed
        }
        defer { Darwin.close(descriptor) }
        guard Darwin.fchflags(descriptor, UInt32(UF_IMMUTABLE)) == 0 else {
            throw CmuxPluginExecutionSnapshotError.entrypointDescriptorFailed
        }
    }

    func clearImmutableFlags(at root: URL) {
        guard fileManager.fileExists(atPath: root.path),
              let enumerator = fileManager.enumerator(
                  at: root,
                  includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                  options: []
              ) else { return }
        var directories: [URL] = []
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            if values?.isSymbolicLink == true {
                continue
            }
            if values?.isDirectory == true {
                directories.append(url)
                continue
            }
            clearImmutableFlag(at: url)
        }
        for directory in directories.sorted(by: { depth(of: $0) > depth(of: $1) }) {
            clearImmutableFlag(at: directory, isDirectory: true)
        }
        clearImmutableFlag(at: root, isDirectory: true)
    }

    func clearImmutableFlag(at url: URL, isDirectory: Bool = false) {
        let flags = O_RDONLY | O_NOFOLLOW | (isDirectory ? O_DIRECTORY : 0)
        let descriptor = Darwin.open(url.path, flags)
        guard descriptor >= 0 else { return }
        _ = Darwin.fchflags(descriptor, UInt32(0))
        Darwin.close(descriptor)
    }

    func depth(of url: URL) -> Int {
        url.standardizedFileURL.pathComponents.count
    }

    func removeStagingRoot(
        _ stagingRoot: URL,
        within rootDirectory: URL? = nil
    ) {
        let root = (rootDirectory ?? rootDirectoryURL).standardizedFileURL
        let candidate = stagingRoot.standardizedFileURL
        guard canonicalURL(candidate).path.hasPrefix(canonicalURL(root).path + "/") else { return }
        guard let values = try? candidate.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
              values.isDirectory == true,
              values.isSymbolicLink != true else {
            try? fileManager.removeItem(at: candidate)
            removeEmptySnapshotRoot(at: root)
            return
        }
        clearImmutableFlags(at: candidate)
        try? fileManager.removeItem(at: candidate)
        removeEmptySnapshotRoot(at: root)
    }

    /// Recovers UUID-named snapshots left by a crashed or force-quit host.
    /// The default root is process-scoped, and only roots older than a day are
    /// removed. Across dead process roots, at most two recent snapshots survive;
    /// with the 256 MiB bundle/interpreter caps this also bounds retained bytes.
    func pruneOrphanedSnapshots() {
        let cutoff = Date().addingTimeInterval(-Self.orphanSnapshotAge)
        let rootName = rootDirectoryURL.lastPathComponent
        let roots: [URL]
        if rootName.hasPrefix("cmux-plugin-snapshots-") {
            let parent = rootDirectoryURL.deletingLastPathComponent()
            roots = (try? fileManager.contentsOfDirectory(
                at: parent,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles]
            ))?.filter { $0.lastPathComponent.hasPrefix("cmux-plugin-snapshots-") }
                ?? [rootDirectoryURL]
        } else {
            roots = [rootDirectoryURL]
        }

        var orphaned: [(url: URL, root: URL, modified: Date)] = []
        for root in roots {
            guard let rootValues = try? root.resourceValues(
                forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
            ),
                  rootValues.isDirectory == true,
                  rootValues.isSymbolicLink != true else {
                continue
            }
            if canonicalURL(root) != canonicalURL(rootDirectoryURL),
               let pid = snapshotRootProcessID(root.lastPathComponent),
               isProcessAlive(pid) {
                continue
            }
            guard let entries = try? fileManager.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            for entry in entries {
                guard UUID(uuidString: entry.lastPathComponent) != nil,
                      let values = try? entry.resourceValues(
                          forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
                      ),
                      values.isDirectory == true,
                      values.isSymbolicLink != true,
                      !activeSnapshotStagingRoots.contains(where: {
                          canonicalURL($0) == canonicalURL(entry)
                      }),
                      let attributes = try? fileManager.attributesOfItem(atPath: entry.path),
                      let modified = attributes[.modificationDate] as? Date else {
                    continue
                }
                orphaned.append((entry, root, modified))
            }
        }
        for (index, candidate) in orphaned
            .sorted(by: { $0.modified > $1.modified })
            .enumerated()
        where index >= Self.maximumOrphanSnapshotCount || candidate.modified < cutoff {
            removeStagingRoot(candidate.url, within: candidate.root)
        }
        roots.forEach { removeEmptySnapshotRoot(at: $0) }
    }

    func removeEmptySnapshotRoot(at root: URL) {
        let root = root.standardizedFileURL
        guard root.lastPathComponent.hasPrefix("cmux-plugin-snapshots-"),
              let values = try? root.resourceValues(
                  forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
              ),
              values.isDirectory == true,
              values.isSymbolicLink != true,
              let entries = try? fileManager.contentsOfDirectory(
                  at: root,
                  includingPropertiesForKeys: nil,
                  options: []
              ),
              entries.isEmpty else {
            return
        }
        if canonicalURL(root) != canonicalURL(rootDirectoryURL),
           let pid = snapshotRootProcessID(root.lastPathComponent),
           isProcessAlive(pid) {
            return
        }
        clearImmutableFlags(at: root)
        try? fileManager.removeItem(at: root)
    }

    func snapshotRootProcessID(_ name: String) -> pid_t? {
        guard let raw = name.split(separator: "-").last,
              let value = Int32(raw),
              value > 1 else { return nil }
        return value
    }

    func isProcessAlive(_ processID: pid_t) -> Bool {
        Darwin.kill(processID, 0) == 0 || errno == EPERM
    }

    /// Resolves system aliases such as `/var` before lexical path comparisons.
    /// The caller still performs symlink checks on the original URL so this
    /// helper cannot turn an untrusted link into an apparently safe path.
    func canonicalURL(_ url: URL) -> URL {
        let standardized = url.standardizedFileURL
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        let resolved = standardized.path.withCString { pointer in
            Darwin.realpath(pointer, &buffer)
        }
        guard resolved != nil else {
            return URL(fileURLWithPath: standardized.path)
        }
        let length = buffer.firstIndex(of: 0) ?? buffer.count
        let path = String(
            decoding: buffer[..<length].map { UInt8(bitPattern: $0) },
            as: UTF8.self
        )
        // Path identity must not depend on URL's directory hint. FileManager
        // enumeration and our staging URLs can represent the same directory
        // with different `hasDirectoryPath` values.
        return URL(fileURLWithPath: path)
    }

    func readBoundedFile(at url: URL, maximumBytes: Int) -> Data? {
        let descriptor = Darwin.open(
            url.path,
            O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK
        )
        guard descriptor >= 0 else { return nil }
        defer { Darwin.close(descriptor) }
        var metadata = Darwin.stat()
        guard Darwin.fstat(descriptor, &metadata) == 0,
              (metadata.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
              metadata.st_size >= 0,
              UInt64(metadata.st_size) <= UInt64(maximumBytes) else {
            return nil
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        var data = Data()
        do {
            while data.count <= maximumBytes {
                let remaining = maximumBytes + 1 - data.count
                let chunk = try handle.read(upToCount: min(64 * 1024, remaining)) ?? Data()
                if chunk.isEmpty { break }
                data.append(chunk)
            }
        } catch {
            return nil
        }
        return data.count <= maximumBytes ? data : nil
    }
}
