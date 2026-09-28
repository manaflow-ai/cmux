/// One line of ANSI art as styled runs.
public struct ANSIArtLine: Hashable, Sendable {
    /// The line's runs, left to right. Adjacent runs have different styles.
    public var runs: [ANSIArtRun]

    /// Creates a line from its runs.
    ///
    /// - Parameter runs: The styled runs, left to right.
    public init(runs: [ANSIArtRun]) {
        self.runs = runs
    }

    /// The line's printable text without styling.
    public var text: String {
        runs.map(\.text).joined()
    }

    /// The number of character cells the line occupies, per
    /// ``ANSIArt/cellWidth(of:)``.
    public var columnCount: Int {
        runs.reduce(0) { total, run in
            run.text.unicodeScalars.reduce(total) { $0 + ANSIArt.cellWidth(of: $1) }
        }
    }
}
