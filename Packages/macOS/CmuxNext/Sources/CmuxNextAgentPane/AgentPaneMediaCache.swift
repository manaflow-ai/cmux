import Darwin
import Foundation

/// Downloaded clips owned by one process lifetime, separate from user files and legacy loose clips.
/// All filesystem work runs on this actor's executor. A kernel lease survives suspension and is
/// released on exit (including crashes); neither PID reuse nor a clip's age can expire a live owner.
actor AgentPaneMediaCache {
    private let root: URL
    private var rootDescriptor: Int32 = -1
    private var ownerDescriptor: Int32 = -1
    private var leaseDescriptor: Int32 = -1
    private var ownerName: String?
    private var finished = false

    init(root: URL) { self.root = root }

    deinit {
        if ownerDescriptor >= 0 { close(ownerDescriptor) }
        if leaseDescriptor >= 0 { close(leaseDescriptor) }
        if rootDescriptor >= 0 { close(rootDescriptor) }
    }

    /// Stores only a sniffed, supported container. A failed or cancelled write is never granted.
    func store(_ data: Data, ext: String) -> URL? {
        guard !finished, !Task.isCancelled,
              AgentPaneMediaGrants.types[ext] != nil, AgentPaneMediaGrants.sniff(data) == ext,
              prepare(), let ownerName else { return nil }
        let name = UUID().uuidString.lowercased() + "." + ext
        let descriptor = openat(ownerDescriptor, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { return nil }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        do {
            try handle.write(contentsOf: data)
            try handle.close()
            guard !Task.isCancelled else {
                unlinkat(ownerDescriptor, name, 0)
                return nil
            }
            return root.appending(path: ownerName).appending(path: name)
        } catch {
            try? handle.close()
            unlinkat(ownerDescriptor, name, 0)
            return nil
        }
    }

    /// Deletes only this owner's copy after its grant expires; never resolves an arbitrary path.
    func remove(_ file: URL) {
        guard let ownerName,
              file.deletingLastPathComponent().standardizedFileURL.path == root.appending(path: ownerName).standardizedFileURL.path,
              Self.isClip(file.lastPathComponent), ownerDescriptor >= 0 else { return }
        unlinkat(ownerDescriptor, file.lastPathComponent, 0)
    }

    /// Relinquishes ownership once every consumer has stopped. Production retains its cache for
    /// the process lifetime, so a pane closing never drops another pane's playback lease.
    func finish() {
        finished = true
        if ownerDescriptor >= 0 { close(ownerDescriptor); ownerDescriptor = -1 }
        if leaseDescriptor >= 0 { close(leaseDescriptor); leaseDescriptor = -1 }
        if rootDescriptor >= 0 { close(rootDescriptor); rootDescriptor = -1 }
    }

    private func prepare() -> Bool {
        if ownerDescriptor >= 0 { return true }
        if mkdir(root.path, 0o700) != 0, errno != EEXIST { return false }
        let rootFD = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard rootFD >= 0 else { return false }
        guard Self.isPrivate(rootFD, kind: S_IFDIR) else { close(rootFD); return false }
        let owner = "v1-" + UUID().uuidString.lowercased()
        let leaseName = "." + owner + ".lock"
        let lease = openat(rootFD, leaseName, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard lease >= 0 else { close(rootFD); return false }
        // concurrency-allow: nonblocking kernel lease coordinates different app processes, not actor state.
        // Publish the directory only AFTER taking the lease; sweepers never inspect bare lease files.
        guard flock(lease, LOCK_EX | LOCK_NB) == 0, mkdirat(rootFD, owner, 0o700) == 0 else {
            close(lease)
            unlinkat(rootFD, leaseName, 0)
            close(rootFD)
            return false
        }
        let directory = openat(rootFD, owner, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directory >= 0 else {
            unlinkat(rootFD, owner, AT_REMOVEDIR)
            close(lease)
            unlinkat(rootFD, leaseName, 0)
            close(rootFD)
            return false
        }
        rootDescriptor = rootFD
        ownerDescriptor = directory
        leaseDescriptor = lease
        ownerName = owner
        sweepOrphans()
        return true
    }

    /// One finite sweep when this owner first stores a clip; no timer, observer or per-frame work.
    /// Unknown entries and legacy loose files have no ownership proof and are never removed.
    private func sweepOrphans() {
        for name in Self.names(in: rootDescriptor) where Self.isOwner(name) && name != ownerName {
            let directory = openat(rootDescriptor, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard directory >= 0 else { continue }
            defer { close(directory) }
            guard Self.isPrivate(directory, kind: S_IFDIR) else { continue }
            let leaseName = "." + name + ".lock"
            let lease = openat(rootDescriptor, leaseName, O_RDWR | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            guard lease >= 0 else { continue }
            defer { close(lease) }
            // Any lock or metadata error means leave it alone, including live owners and symlinks.
            guard Self.isPrivate(lease, kind: S_IFREG), flock(lease, LOCK_EX | LOCK_NB) == 0 else { continue }
            let names = Self.names(in: directory)
            // Never recursively remove a directory or follow a path supplied by its contents.
            for clip in names where Self.isClip(clip) {
                var info = stat()
                guard fstatat(directory, clip, &info, AT_SYMLINK_NOFOLLOW) == 0,
                      info.st_mode & S_IFMT == S_IFREG, info.st_uid == geteuid(), info.st_nlink == 1 else { continue }
                unlinkat(directory, clip, 0)
            }
            if unlinkat(rootDescriptor, name, AT_REMOVEDIR) == 0 {
                unlinkat(rootDescriptor, leaseName, 0)
            }
        }
    }

    private nonisolated static func isPrivate(_ descriptor: Int32, kind: mode_t) -> Bool {
        var info = stat()
        return fstat(descriptor, &info) == 0 && info.st_mode & S_IFMT == kind &&
            info.st_uid == geteuid() && info.st_mode & 0o077 == 0 && (kind != S_IFREG || info.st_nlink == 1)
    }

    private nonisolated static func isOwner(_ name: String) -> Bool {
        name.hasPrefix("v1-") && UUID(uuidString: String(name.dropFirst(3)))?.uuidString.lowercased() == String(name.dropFirst(3))
    }

    private nonisolated static func isClip(_ name: String) -> Bool {
        let parts = name.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 2 && UUID(uuidString: String(parts[0]))?.uuidString.lowercased() == String(parts[0]) &&
            AgentPaneMediaGrants.types[String(parts[1])] != nil
    }

    /// Enumerates the opened directory itself, even if a path component is renamed or replaced.
    private nonisolated static func names(in descriptor: Int32) -> [String] {
        let copy = dup(descriptor)
        guard copy >= 0 else { return [] }
        guard let directory = fdopendir(copy) else { close(copy); return [] }
        defer { closedir(directory) }
        rewinddir(directory)
        var names: [String] = []
        while let entry = readdir(directory) {
            let capacity = Int(entry.pointee.d_namlen) + 1
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: capacity) { String(cString: $0) }
            }
            if name != ".", name != ".." { names.append(name) }
        }
        return names
    }
}
