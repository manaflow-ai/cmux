extension MainTaskBoard {
    /// The source location a task was posted from: Chrome's `posted_from` (`FROM_HERE`,
    /// base/location.h), built from the ``MainPostSite`` only when a reader asks.
    public struct PostedFrom: Sendable, Equatable, CustomStringConvertible {
        /// The posting file's `#fileID` (`Module/File.swift`).
        public var file: String
        /// The posting line.
        public var line: UInt

        /// A posting location from its `#fileID` and line.
        public init(file: String, line: UInt) {
            self.file = file
            self.line = line
        }

        public var description: String { "\(file):\(line)" }
    }
}
