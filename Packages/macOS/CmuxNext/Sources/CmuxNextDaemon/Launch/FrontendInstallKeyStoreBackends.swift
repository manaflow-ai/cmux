public import Foundation

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
        let fresh = FrontendInstallKey.generate()
        // Created 0600 in one step (O_EXCL; never a chmod afterwards). A
        // racing launch that created it first wins; read that one.
        let fd = open(file.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return read() }
        // A umask may only narrow the mode; anything but 0600 is not ours.
        var created = stat()
        guard fstat(fd, &created) == 0, created.st_mode & 0o777 == 0o600 else {
            close(fd)
            try? FileManager.default.removeItem(at: file)
            return nil
        }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        do {
            try handle.write(contentsOf: fresh.payload)
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
        let fd = open(file.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == owner,
              info.st_mode & 0o777 == 0o600 else { return nil }
        guard let data = try? handle.read(upToCount: 512) else { return nil }
        return FrontendInstallKey(payload: data)
    }
}
