public import Foundation

/// Finder's rule for what a drop does (on the same volume it moves, onto
/// another it copies; holding Option copies, holding Command moves), asked of
/// Rust (cmux-layout-reducer `drop_rules`, op `drop_transfer_mode`). This
/// reads the volumes; Rust decides.
public struct DropPolicy: Sendable {
    private let volumeOf: @Sendable (URL) -> Int?

    /// Makes a policy.
    /// - Parameter volumeOf: The device id of a path (a seam for tests). Defaults to `stat`'s `st_dev`.
    public init(volumeOf: @escaping @Sendable (URL) -> Int? = { url in
        var info = stat()
        return stat(url.path, &info) == 0 ? Int(info.st_dev) : nil
    }) {
        self.volumeOf = volumeOf
    }

    /// The mode for dropping `sources` into `destination`.
    /// - Parameters:
    ///   - option: Option is held (copy).
    ///   - command: Command is held (move).
    public func mode(for sources: [URL], into destination: URL, option: Bool, command: Bool) -> TransferMode {
        let request = DropTransferWire.Request(sources: sources.map(volumeOf), destination: volumeOf(destination), option: option, command: command)
        return DropTransferWire.ask(request).flatMap { TransferMode(rawValue: $0.mode) } ?? .copy
    }
}
