public import Foundation

/// Reads and writes the managed `# cmux themes` block in one Ghostty config
/// file. `cmux themes` and the Settings theme gallery share this writer.
///
/// Every write re-reads the file and replaces only the block, so edits made
/// elsewhere in the file (by hand or by another cmux process) are kept.
public struct CmuxManagedThemeConfigFile: Equatable, Sendable {
    /// Why a theme write was refused before touching the file.
    public enum WriteError: Error, Equatable {
        /// The value would span several config lines.
        case multilineThemeValue
    }

    /// The Ghostty config file that holds the managed block.
    public let url: URL
    private var block: CmuxManagedThemeBlock { CmuxManagedThemeBlock() }

    /// Creates a writer for the config file at `url`.
    /// - Parameter url: Usually `CmuxGhosttyConfigPathResolver.editableConfigURL(...)`.
    public init(url: URL) {
        self.url = url
    }

    /// The file's current contents, or `nil` when it does not exist.
    /// - Throws: Any read error other than a missing file.
    public func readContents() throws -> String? {
        do {
            return try String(contentsOf: url, encoding: .utf8)
        } catch {
            guard Self.isFileNotFound(error) else { throw error }
            return nil
        }
    }

    /// The raw `theme` value in the file's managed block, or `nil` when the
    /// file or the block is missing.
    /// - Throws: Any read error other than a missing file.
    public func managedThemeValue() throws -> String? {
        try readContents().flatMap(block.themeValue(in:))
    }

    /// Replaces the managed block with `theme = rawThemeValue`, creating the
    /// file and its directory when needed. Lines outside the block are kept.
    /// - Throws: ``WriteError/multilineThemeValue`` for a value containing a
    ///   line break, or the underlying file error.
    public func write(rawThemeValue: String) throws {
        guard rawThemeValue.rangeOfCharacter(from: .newlines) == nil else {
            throw WriteError.multilineThemeValue
        }
        let existing = try readContents() ?? ""
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: nil
        )
        try block.applying(rawThemeValue: rawThemeValue, to: existing)
            .write(to: url, atomically: true, encoding: .utf8)
    }

    /// Removes the managed block, deleting the file when nothing else is left.
    /// - Throws: Any read, write or delete error other than a missing file.
    public func clear() throws {
        guard let existing = try readContents() else { return }
        guard let remaining = block.clearing(existing) else {
            do {
                try FileManager.default.removeItem(at: url)
            } catch {
                guard Self.isFileNotFound(error) else { throw error }
            }
            return
        }
        try remaining.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Writes `rawThemeValue` into the block, or clears the block when it is
    /// `nil`. Use it to put back a value read with ``managedThemeValue()``.
    /// - Throws: The same errors as ``write(rawThemeValue:)`` and ``clear()``.
    public func setManagedThemeValue(_ rawThemeValue: String?) throws {
        if let rawThemeValue {
            try write(rawThemeValue: rawThemeValue)
        } else {
            try clear()
        }
    }

    private static func isFileNotFound(_ error: any Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain {
            return nsError.code == NSFileNoSuchFileError || nsError.code == NSFileReadNoSuchFileError
        }
        if nsError.domain == NSPOSIXErrorDomain {
            return nsError.code == Int(ENOENT)
        }
        return false
    }
}
