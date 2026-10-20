public import Foundation

/// File name rules a grid's rename and drop share: what a valid new name is,
/// and the free name a copy takes (`Shot.png`, `Shot 2.png`, ...).
public nonisolated struct FileGridNaming: Sendable {
    /// Why a name was refused.
    public enum Refusal: Error, Equatable, Sendable {
        /// Empty, `.`/`..`, or contains `/` or `:`.
        case invalid
        /// Another item in the folder has that name.
        case exists
    }

    private let exists: @Sendable (URL) -> Bool

    /// Makes the rules over a file-existence check.
    ///
    /// - Parameter exists: whether a file is at a URL (default: `FileManager`).
    public init(exists: @escaping @Sendable (URL) -> Bool = { FileManager().fileExists(atPath: $0.path) }) {
        self.exists = exists
    }

    /// The trimmed name when it is a valid file name.
    ///
    /// - Parameter name: what the person typed.
    /// - Returns: the name to use.
    /// - Throws: ``Refusal/invalid``.
    public func validated(_ name: String) throws(Refusal) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != ".", trimmed != "..", !trimmed.contains("/"), !trimmed.contains(":") else {
            throw .invalid
        }
        return trimmed
    }

    /// The URL `file` takes when renamed to `name` in its folder.
    ///
    /// - Parameters:
    ///   - file: the file.
    ///   - name: the new name.
    /// - Returns: the destination, or `file` itself when the name is unchanged.
    /// - Throws: ``Refusal/invalid`` or ``Refusal/exists``.
    public func renamed(_ file: URL, to name: String) throws(Refusal) -> URL {
        let name = try validated(name)
        let target = file.deletingLastPathComponent().appendingPathComponent(name)
        if target.path == file.path { return file }
        // A case-only rename is the same file on a case-insensitive volume.
        if target.path.lowercased() != file.path.lowercased(), exists(target) { throw .exists }
        return target
    }

    /// The first free URL for `name` in `folder`: the name itself, then `base 2.ext`, `base 3.ext`, ...
    ///
    /// - Parameters:
    ///   - name: the wanted file name.
    ///   - folder: the destination folder.
    public func free(_ name: String, in folder: URL) -> URL {
        let first = folder.appendingPathComponent(name)
        guard exists(first) else { return first }
        let ext = (name as NSString).pathExtension
        let base = (name as NSString).deletingPathExtension
        let numbered = (2...).lazy.map { number in
            folder.appendingPathComponent(ext.isEmpty ? "\(base) \(number)" : "\(base) \(number).\(ext)")
        }
        // A folder holds finitely many names, so a free one always comes.
        return numbered.first { !exists($0) } ?? first
    }
}
