public import CmuxNextActions
import Foundation

/// The plain argument reads of the Cloud machine actions (`cloud read-file --path`, `cloud copy-port --port`).
public extension ActionInvocation {
    /// `--path`: an absolute guest path with no `..` and no NUL, at most 4096 bytes.
    func cloudFilePath() throws -> String {
        guard let path = self["path"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              path.hasPrefix("/"), !path.contains("\0"), !path.split(separator: "/").contains(".."), path.utf8.count <= 4096 else {
            throw ActionFailure(message: CloudStrings.filePathRequired)
        }
        return path
    }

    /// `--port`: 1 to 65535.
    func cloudPort() throws -> Int {
        guard let port = self["port"]?.intValue, (1...65535).contains(port) else { throw ActionFailure(message: CloudStrings.invalidPort) }
        return port
    }
}
