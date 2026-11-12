import Foundation

extension String {
    private static let remotePathShellSafe = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789/._-+,:@%=")

    /// This remote path quoted so a POSIX shell reads it as one literal word.
    ///
    /// Paths made only of characters no shell treats specially pass through
    /// unchanged, so the common case stays readable in the terminal.
    public var remotePathShellWord: String {
        if !isEmpty, allSatisfy(Self.remotePathShellSafe.contains) { return self }
        return "'" + replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
