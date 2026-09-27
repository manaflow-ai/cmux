public import Foundation

/// Reads and writes the managed `# cmux themes` block in one Ghostty config
/// file. `cmux themes` and the Settings theme gallery share this writer.
public struct CmuxManagedThemeConfigFile: Equatable, Sendable {
    /// Why a theme write was refused before touching the file.
    public enum WriteError: Error, Equatable {
        /// The value would span several config lines.
        case multilineThemeValue
    }

    /// The Ghostty config file that holds the managed block.
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    /// The file's current contents, or `nil` when it does not exist.
    public func readContents() throws -> String? {
        do {
            return try String(contentsOf: url, encoding: .utf8)
        } catch {
            guard Self.isFileNotFound(error) else { throw error }
            return nil
        }
    }

    /// Replaces the managed block with `theme = rawThemeValue`, creating the
    /// file and its directory when needed. Lines outside the block are kept.
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
        try CmuxManagedThemeBlock.applying(rawThemeValue: rawThemeValue, to: existing)
            .write(to: url, atomically: true, encoding: .utf8)
    }

    /// Removes the managed block, deleting the file when nothing else is left.
    public func clear() throws {
        guard let existing = try readContents() else { return }
        try restore(CmuxManagedThemeBlock.clearing(existing))
    }

    /// Puts back contents captured by ``readContents()``: `nil` removes the file.
    public func restore(_ contents: String?) throws {
        guard let contents else {
            do {
                try FileManager.default.removeItem(at: url)
            } catch {
                guard Self.isFileNotFound(error) else { throw error }
            }
            return
        }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: nil
        )
        try contents.write(to: url, atomically: true, encoding: .utf8)
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
