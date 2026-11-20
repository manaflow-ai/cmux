public import Foundation
import Darwin

/// The capture's three-part ownership claim. It contains no account or credentials.
public struct CaptureLeaseBinding: Codable, Equatable, Sendable {
    public let leaseID: String
    public let bundleID: String
    public let privateRoot: String

    public init?(fields: [String: Any]) {
        guard Set(fields.keys) == ["lease_id", "bundle_id", "private_root"],
              let lease = fields["lease_id"] as? String, lease.count == 24,
              lease.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              let bundle = fields["bundle_id"] as? String, bundle.hasPrefix("com.cmuxterm.app.debug."), bundle.count > "com.cmuxterm.app.debug.".count,
              bundle.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 46 || $0 == 45 }),
              let root = fields["private_root"] as? String, root.hasPrefix("/"), root != "/", !root.utf8.contains(0),
              URL(fileURLWithPath: root).standardizedFileURL.path == root else { return nil }
        leaseID = lease; bundleID = bundle; privateRoot = root
    }

    /// A real private HOME, not a symlink, shared directory or the login account's home.
    public func owns(stateDirectory: String, home: String) -> Bool {
        guard home == privateRoot,
              URL(fileURLWithPath: privateRoot).resolvingSymlinksInPath().path == privateRoot,
              URL(fileURLWithPath: stateDirectory).resolvingSymlinksInPath().path == stateDirectory,
              stateDirectory.hasPrefix(privateRoot + "/"),
              let login = getpwuid(getuid()), String(cString: login.pointee.pw_dir) != privateRoot else { return false }
        var info = stat()
        return lstat(privateRoot, &info) == 0 && info.st_uid == getuid()
            && (info.st_mode & S_IFMT) == S_IFDIR && (info.st_mode & 0o077) == 0
    }
}
