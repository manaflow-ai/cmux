public import Foundation

/// Opens diagnostic log files for appending, such as the debug logs under `/tmp`.
public enum OwnedLogFile {
    /// Returns a handle positioned at the end of the file at `path`, creating
    /// the file when missing, or nil when it cannot be opened.
    public static func openForAppending(atPath path: String) -> FileHandle? {
        if FileManager.default.fileExists(atPath: path) == false {
            FileManager.default.createFile(atPath: path, contents: nil)
        }
        guard let handle = FileHandle(forWritingAtPath: path) else {
            return nil
        }
        guard (try? handle.seekToEnd()) != nil else {
            try? handle.close()
            return nil
        }
        return handle
    }
}
