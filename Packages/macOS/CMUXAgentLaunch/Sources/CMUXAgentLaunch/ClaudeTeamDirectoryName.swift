/// A canonical direct-child directory name for a Claude automatic team.
struct ClaudeTeamDirectoryName: Equatable {
    /// The canonical filesystem component produced by Claude's team sanitizer.
    let rawValue: String

    /// Creates the directory name Claude derives from an automatic-team name.
    ///
    /// Claude replaces every non-ASCII-alphanumeric character and then
    /// lowercases the result. This intentionally differs from task-list naming.
    ///
    /// - Parameter teamName: The unsanitized name stored in `config.json`.
    init?(teamName: String) {
        let hyphen: UInt16 = 0x2D
        let codeUnits = teamName.utf16.map { codeUnit in
            switch codeUnit {
            case 0x61...0x7A, 0x30...0x39:
                return codeUnit
            case 0x41...0x5A:
                return codeUnit + 0x20
            default:
                return hyphen
            }
        }
        let rawValue = String(decoding: codeUnits, as: UTF16.self)
        guard !rawValue.isEmpty else { return nil }
        self.rawValue = rawValue
    }
}
