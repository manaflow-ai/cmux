public import Foundation

/// Resolves the pure, process-independent pieces of a `pi`-compatible agent's
/// on-disk session layout: the default sessions root, the per-project directory
/// name `pi` derives from a working directory, and the newest `.jsonl` rollout
/// in a directory.
///
/// `pi`-compatible agents (`pi`, `omp`, and friends) write one JSONL session file
/// per conversation under a sessions root (default `~/.pi/agent/sessions`),
/// optionally nested in a per-project subdirectory whose name is the working
/// directory with separators replaced by dashes and wrapped in `--…--`. This type
/// owns only the path/file math that needs nothing but a working directory and a
/// `FileManager`; the process- and registration-coupled directory selection
/// (env overrides, omp roots, configured directories) stays app-side and forwards
/// the pure pieces here.
///
/// Mirrors `CodexSessionResolver`: instance methods over a constructor-injected
/// `FileManager` so tests can point resolution at a temporary tree.
public struct PiSessionResolver {
    private let fileManager: FileManager

    /// Creates a resolver.
    ///
    /// - Parameter fileManager: Injected so tests can point resolution at a
    ///   temporary sessions tree; defaults to `.default`.
    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    /// The default sessions root `pi`-compatible agents write under:
    /// `<homeDirectory>/.pi/agent/sessions`, with `homeDirectory` standardized first.
    ///
    /// - Parameter homeDirectory: The home directory to root under; defaults to
    ///   `NSHomeDirectory()`.
    public func defaultSessionsRoot(homeDirectory: String = NSHomeDirectory()) -> String {
        let standardizedHome = (homeDirectory as NSString).standardizingPath
        return (standardizedHome as NSString).appendingPathComponent(".pi/agent/sessions")
    }

    /// The per-project subdirectory name `pi` derives from a working directory:
    /// the path with a leading `/` dropped, `/` and `:` replaced by `-`, wrapped
    /// in `--…--`. Returns `nil` for an empty or fully-sanitized-away path.
    ///
    /// - Parameter workingDirectory: The agent's working directory.
    public func projectDirectoryName(for workingDirectory: String) -> String? {
        let trimmed = workingDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let withoutLeadingSlash = trimmed.hasPrefix("/") ? String(trimmed.dropFirst()) : trimmed
        let sanitized = withoutLeadingSlash
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        guard !sanitized.isEmpty else { return nil }
        return "--\(sanitized)--"
    }

    /// The newest regular `.jsonl` file directly enumerable under `directory`
    /// (skipping hidden files), by content-modification date, or `nil` when the
    /// directory is missing/not-a-directory or holds no readable `.jsonl` file.
    ///
    /// - Parameter directory: The directory to scan for rollout files.
    public func newestJSONLFile(in directory: String) -> URL? {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: directory, isDirectory: &isDirectory),
              isDirectory.boolValue,
              let enumerator = fileManager.enumerator(
                  at: URL(fileURLWithPath: directory, isDirectory: true),
                  includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
                  options: [.skipsHiddenFiles]
              ) else {
            return nil
        }

        var newest: (url: URL, modified: Date)?
        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey])
            guard values?.isRegularFile == true, let modified = values?.contentModificationDate else { continue }
            if newest == nil || modified > newest!.modified {
                newest = (url, modified)
            }
        }
        return newest?.url
    }
}
