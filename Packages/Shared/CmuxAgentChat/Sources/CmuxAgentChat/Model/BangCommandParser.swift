import Foundation

/// Finds suggested bang commands in original agent messages without screen-row reconstruction.
public enum BangCommandParser {
    /// Returns complete command text, preserving paths, quoting and real script newlines.
    public static func commands(in text: String) -> [String] {
        []
    }
}
