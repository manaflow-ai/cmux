package import Foundation

/// A tab's working folder (#16620). New Browser Tab never takes an address from
/// the selected tab: it opens blank (#37384).
package struct WorkingURL {
    package init() {}

    /// An agent's cwd comes from its page: use it only as an absolute path
    /// to a directory on this Mac (a remote agent's folder is not one).
    package static func isDirectory(_ path: String, fileManager: FileManager = .default) -> Bool {
        var directory: ObjCBool = false
        return path.hasPrefix("/") && fileManager.fileExists(atPath: path, isDirectory: &directory) && directory.boolValue
    }
}

