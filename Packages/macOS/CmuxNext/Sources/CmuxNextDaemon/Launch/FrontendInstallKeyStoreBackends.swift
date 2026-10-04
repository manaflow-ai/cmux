public import Foundation
import LocalAuthentication
import Security

// The two `FrontendInstallKeyStore` backends (see that protocol).

public struct KeychainFrontendInstallKeyStore: FrontendInstallKeyStore {
    public let service: String
    public let account: String

    public init(service: String, account: String) {
        self.service = service
        self.account = account
    }

    public func loadOrCreate() -> FrontendInstallKey? {
        switch read() {
        case .found(let key): return key
        case .unreadable: return nil
        case .absent: break
        }
        let fresh = FrontendInstallKey.generate()
        var add = base()
        add[kSecValueData as String] = fresh.payload
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        add[kSecAttrLabel as String] = "cmux frontend install key"
        let status = SecItemAdd(add as CFDictionary, nil)
        if status == errSecSuccess { return fresh }
        // Another launch created it first: use that one.
        if status == errSecDuplicateItem, case .found(let key) = read() { return key }
        return nil
    }

    private enum ReadResult { case found(FrontendInstallKey), absent, unreadable }

    private func base() -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    private func read() -> ReadResult {
        var query = base()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        let context = LAContext()
        context.interactionNotAllowed = true
        query[kSecUseAuthenticationContext as String] = context
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return .absent }
        guard status == errSecSuccess, let data = result as? Data, let key = FrontendInstallKey(payload: data) else {
            return .unreadable
        }
        return .found(key)
    }
}

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
