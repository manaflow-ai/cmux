import Foundation

/// Reads file status through `lstat`.
struct SystemGitFileStatusReader: GitFileStatusReading {
    func status(atPath path: String) -> GitFileStatus? {
        var statValue = stat()
        guard lstat(path, &statValue) == 0 else {
            return nil
        }
        return GitFileStatus(statValue: statValue)
    }
}
