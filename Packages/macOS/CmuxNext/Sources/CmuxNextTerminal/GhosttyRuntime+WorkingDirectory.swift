import Foundation
import GhosttyNextKit

/// Ghostty's `window-inherit-working-directory`, `tab-inherit-working-directory`
/// and `split-inherit-working-directory`, with `working-directory`
/// (NEW-TERMINAL-INHERITS-CWD, cx-zld). The three inherit keys default to true,
/// as in Ghostty: a new terminal starts in the focused terminal's folder (the
/// daemon's new-terminal resolver). A key set to false makes that kind of new
/// terminal start in the `working-directory` folder instead, as Ghostty does;
/// the home folder when that key is unset or `inherit` (Ghostty's default for
/// an app launched from the Dock or `open`).
public nonisolated struct GhosttyWorkingDirectoryInheritance: Equatable, Sendable {
    /// What kind of new terminal asks.
    public enum Kind: Sendable {
        /// A new workspace (Ghostty's new window).
        case window
        case tab
        case split
    }

    public var window: Bool
    public var tab: Bool
    public var split: Bool
    /// The `working-directory` folder (absolute, `~/` expanded, `home` as the home folder);
    /// nil when the key is unset or `inherit`.
    public var workingDirectory: String?

    public init(window: Bool = true, tab: Bool = true, split: Bool = true, workingDirectory: String? = nil) {
        self.window = window
        self.tab = tab
        self.split = split
        self.workingDirectory = workingDirectory
    }

    init(config: ghostty_config_t, files: [String]) {
        var window = true, tab = true, split = true
        _ = Self.get(config, &window, key: "window-inherit-working-directory")
        _ = Self.get(config, &tab, key: "tab-inherit-working-directory")
        _ = Self.get(config, &split, key: "split-inherit-working-directory")
        self.init(window: window, tab: tab, split: split, workingDirectory: Self.workingDirectory(inFiles: files))
    }

    /// `ghostty_config_get` for one key, callable off the main actor.
    private static func get<T: BitwiseCopyable>(_ config: ghostty_config_t, _ value: inout T, key: String) -> Bool {
        withUnsafeMutablePointer(to: &value) { pointer in
            key.withCString { ghostty_config_get(config, pointer, $0, UInt(key.utf8.count)) }
        }
    }

    /// Whether a new terminal of `kind` inherits the focused terminal's folder.
    public func inherits(_ kind: Kind) -> Bool {
        switch kind {
        case .window: window
        case .tab: tab
        case .split: split
        }
    }

    /// The folder a new terminal of `kind` must start in when its caller named
    /// none: nil while it inherits (the caller's folder logic and the daemon's
    /// resolver decide), else the `working-directory` folder, else the home folder.
    public func uninheritedStart(_ kind: Kind, home: String? = nil) -> String? {
        inherits(kind) ? nil : defaultStart(home: home)
    }

    /// Where a new terminal starts with no folder to inherit (Ghostty's first window):
    /// the `working-directory` folder, else the home folder.
    public func defaultStart(home: String? = nil) -> String {
        workingDirectory ?? home ?? NSHomeDirectory()
    }

    /// The `working-directory` value of the loaded config files, read in load order (a later
    /// line wins). libghostty has no getter for this key (`WorkingDirectory` has no `cval`),
    /// so this reads the files as ``GhosttyConfigFontFamily`` does.
    static func workingDirectory(inFiles paths: [String], home: String = NSHomeDirectory()) -> String? {
        var value: String?
        for path in paths {
            guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { continue }
            for raw in text.split(whereSeparator: \.isNewline) {
                let line = raw.trimmingCharacters(in: .whitespaces)
                guard !line.hasPrefix("#"), let equals = line.firstIndex(of: "=") else { continue }
                guard line[..<equals].trimmingCharacters(in: .whitespaces) == "working-directory" else { continue }
                var entry = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
                if entry.count >= 2, entry.hasPrefix("\""), entry.hasSuffix("\"") { entry = String(entry.dropFirst().dropLast()) }
                // An empty value resets the key to its default, as in Ghostty.
                value = entry.isEmpty ? nil : entry
            }
        }
        switch value {
        case nil, "inherit": return nil
        case "home": return home
        case let path?:
            let expanded = path.hasPrefix("~/") ? (home as NSString).appendingPathComponent(String(path.dropFirst(2))) : path
            return expanded.hasPrefix("/") ? expanded : nil
        }
    }
}

extension GhosttyRuntime {
    /// The inherit keys and `working-directory` of the applied config; Ghostty's defaults when
    /// none loaded. Read once per config generation (the files are read for `working-directory`).
    public var workingDirectoryInheritance: GhosttyWorkingDirectoryInheritance {
        guard let config else { return GhosttyWorkingDirectoryInheritance() }
        if let cached = WorkingDirectoryCache.value, cached.generation == configGeneration { return cached.settings }
        let settings = GhosttyWorkingDirectoryInheritance(config: config, files: Self.loadedFiles(of: config))
        WorkingDirectoryCache.value = (configGeneration, settings)
        return settings
    }
}

/// The last read of ``GhosttyRuntime/workingDirectoryInheritance``, by config generation.
private enum WorkingDirectoryCache {
    static var value: (generation: Int, settings: GhosttyWorkingDirectoryInheritance)?
}
