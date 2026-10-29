public import Foundation
import CmuxNextCompat

// The DEV `FrontendInstallKeyStore`: a 0600 file (see that protocol).

public struct FileFrontendInstallKeyStore: FrontendInstallKeyStore {
    public let file: URL
    /// The uid the file must belong to (this user).
    let owner: uid_t

    public init(file: URL) {
        self.init(file: file, owner: geteuid())
    }

    init(file: URL, owner: uid_t) {
        self.file = file
        self.owner = owner
    }

    public func loadOrCreate() -> FrontendInstallKey? {
        if let key = read() { return key }
        // A tag's first launch asks before `server ensure` makes the state
        // directory: make it owner-only now (as ensure does), so the daemon
        // this launch starts gets the key.
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        let fresh = FrontendInstallKey.generate()
        // Created 0600 in one step (O_EXCL; never a chmod afterwards). A
        // racing launch that created it first wins; read that one.
        // SAFETY: open reads the NUL-terminated copy of the path Swift makes for the call.
        let fd = unsafe blockingOpen(file.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return read() }
        // A umask may only narrow the mode; anything but 0600 is not ours.
        var created = stat()
        // SAFETY: fstat writes one struct stat into `created`, a local live for the call.
        guard unsafe fstat(fd, &created) == 0, created.st_mode & 0o777 == 0o600 else {
            close(fd)
            try? FileManager.default.removeItem(at: file)
            return nil
        }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        do {
            try handle.blockingWrite(contentsOf: fresh.payload)
            try handle.close()
        } catch {
            try? FileManager.default.removeItem(at: file)
            return nil
        }
        return fresh
    }

    /// The stored key, only from a regular file of `owner` with mode
    /// exactly 0600.
    private func read() -> FrontendInstallKey? {
        // SAFETY: open reads the NUL-terminated copy of the path Swift makes for the call.
        let fd = unsafe blockingOpen(file.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var info = stat()
        // SAFETY: fstat writes one struct stat into `info`, a local live for the call.
        guard unsafe fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == owner,
              info.st_mode & 0o777 == 0o600 else { return nil }
        guard let data = try? handle.blockingRead(upToCount: 512) else { return nil }
        return FrontendInstallKey(payload: data)
    }
}
