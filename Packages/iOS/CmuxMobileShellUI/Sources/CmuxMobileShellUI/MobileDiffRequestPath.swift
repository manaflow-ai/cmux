import Foundation

/// One diff RPC path paired with its optional rename source.
struct MobileDiffRequestPath: Equatable, Sendable {
    let path: String
    let oldPath: String?

    init(path: String, oldPath: String?) {
        self.path = path
        self.oldPath = oldPath
    }

    init(file: MobileDiffFileChange) {
        path = file.path
        oldPath = file.oldPath
    }

    var wireValue: [String: String] {
        var value = ["path": path]
        if let oldPath {
            value["old_path"] = oldPath
        }
        return value
    }
}
