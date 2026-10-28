public import Foundation
import CmuxNextCompat

/// Finder's rule for what a drop does: on the same volume it moves, onto
/// another it copies; holding Option copies, holding Command moves.
public struct DropPolicy: Sendable {
    private let volumeOf: @Sendable (URL) -> Int?

    /// Makes a policy.
    /// - Parameter volumeOf: The device id of a path (a seam for tests). Defaults to `stat`'s `st_dev`.
    public init(volumeOf: @escaping @Sendable (URL) -> Int? = { url in
        var info = stat()
        // SAFETY: stat reads the NUL-terminated copy of the path made for the call and writes one struct stat into
        // `info`, a local live for the call.
        return unsafe blockingStat(url.path, &info) == 0 ? Int(info.st_dev) : nil
    }) {
        self.volumeOf = volumeOf
    }

    /// The mode for dropping `sources` into `destination`.
    /// - Parameters:
    ///   - option: Option is held (copy).
    ///   - command: Command is held (move).
    public func mode(for sources: [URL], into destination: URL, option: Bool, command: Bool) -> TransferMode {
        if option { return .copy }
        if command { return .move }
        guard let target = volumeOf(destination) else { return .copy }
        return sources.allSatisfy({ volumeOf($0) == target }) ? .move : .copy
    }
}
