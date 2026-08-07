/// A canonical direct-child directory name for a Claude task-list identifier.
struct ClaudeTaskListDirectoryName: Equatable {
    /// The canonical filesystem component produced by Claude's sanitizer.
    let rawValue: String

    /// Creates the directory name Claude derives from a task-list identifier.
    ///
    /// Claude applies `[^a-zA-Z0-9_-]` replacement to UTF-16 code units.
    ///
    /// - Parameter taskListID: The unsanitized task-list identifier.
    init?(taskListID: String) {
        let hyphen: UInt16 = 0x2D
        let codeUnits = taskListID.utf16.map { codeUnit in
            switch codeUnit {
            case 0x61...0x7A, 0x41...0x5A, 0x30...0x39, 0x5F, hyphen:
                return codeUnit
            default:
                return hyphen
            }
        }
        let rawValue = String(decoding: codeUnits, as: UTF16.self)
        guard !rawValue.isEmpty else { return nil }
        self.rawValue = rawValue
    }
}
