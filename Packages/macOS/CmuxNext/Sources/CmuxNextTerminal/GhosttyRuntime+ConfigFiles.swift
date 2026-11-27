public import Foundation
import GhosttyNextKit

/// The files behind the applied Ghostty config (`ghostty_config_loaded_file`):
/// the config files, their `config-file` includes and theme files, in load
/// order. Settings shows the first as the config's source; a reload watcher
/// watches all of them.
extension GhosttyRuntime {
    public var loadedConfigFiles: [String] {
        guard let config else { return [] }
        return Self.loadedFiles(of: config)
    }

    /// The files that can change which Ghostty config is loaded. The finalized
    /// config supplies every file that exists, while these candidates keep a
    /// watch armed for a config created after launch or for a file that wins
    /// precedence when it appears.
    public var liveReloadConfigFiles: [String] {
        var paths = loadedConfigFiles
        if let override = ProcessInfo.processInfo.environment[Self.configOverrideKey], !override.isEmpty {
            paths.append(override)
        }
        paths.append(contentsOf: Self.defaultConfigCandidatePaths())
        var seen = Set<String>()
        return paths.compactMap { raw in
            let path = URL(fileURLWithPath: raw).standardizedFileURL.path
            return seen.insert(path).inserted ? path : nil
        }
    }

    /// Ghostty's macOS search locations, including both spellings accepted by
    /// older and newer releases. This deliberately includes missing files so
    /// a first save is observed without restarting cmux.
    public nonisolated static func defaultConfigCandidatePaths(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        applicationSupportDirectory: URL? = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String] {
        let configHome = environment["XDG_CONFIG_HOME"].flatMap { value in
            let url = URL(fileURLWithPath: value).standardizedFileURL
            return value.isEmpty ? nil : url
        } ?? homeDirectory.appending(path: ".config")
        let ghosttyDirectory = configHome.appendingPathComponent("ghostty", isDirectory: true)
        var paths = [
            ghosttyDirectory.appending(path: "config").path,
            ghosttyDirectory.appending(path: "config.ghostty").path,
        ]
        if let applicationSupportDirectory {
            let native = applicationSupportDirectory.appendingPathComponent("com.mitchellh.ghostty", isDirectory: true)
            paths += [native.appending(path: "config").path, native.appending(path: "config.ghostty").path]
        }
        return paths
    }

    nonisolated static func loadedFiles(of config: ghostty_config_t) -> [String] {
        (0..<ghostty_config_loaded_file_count(config)).compactMap { index in
            ghostty_config_loaded_file(config, index).map { String(cString: $0) }
        }
    }

    /// The files a config made of `path` and its includes reads, for tests.
    nonisolated static func loadedFiles(configFile path: String) -> [String] {
        guard let config = ghostty_config_new() else { return [] }
        defer { ghostty_config_free(config) }
        ghostty_config_load_file(config, path)
        ghostty_config_load_recursive_files(config)
        ghostty_config_finalize(config)
        return loadedFiles(of: config)
    }

    /// The Ghostty config file to edit, chosen as Ghostty.app chooses it
    /// (`ghostty_config_open_path`: App Support before XDG, an existing
    /// non-empty file first). libghostty creates it when none exists.
    public nonisolated static func editableConfigPath() -> String? {
        let path = ghostty_config_open_path()
        defer { ghostty_string_free(path) }
        guard let pointer = path.ptr, path.len > 0 else { return nil }
        return String(decoding: UnsafeRawBufferPointer(start: pointer, count: Int(path.len)), as: UTF8.self)
    }
}
