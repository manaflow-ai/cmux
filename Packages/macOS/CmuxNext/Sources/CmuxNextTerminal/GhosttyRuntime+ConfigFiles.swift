public import Foundation
import GhosttyNextKit

/// The files behind the applied Ghostty config (`ghostty_config_loaded_file`):
/// the config files, their `config-file` includes and theme files, in load
/// order. Settings shows the first as the config's source; a reload watcher
/// watches all of them.
extension GhosttyRuntime {
    /// The config files the launch read into memory (``GhosttyConfigFiles/prefetch(on:)``), set before the
    /// first access to ``shared``: its first load takes them and reads no config file on the main thread.
    /// Nil leaves that load to read the disk.
    public static var launchConfigFiles: GhosttyConfigFiles?

    /// ``launchConfigFiles``, taken once.
    static func takeLaunchConfigFiles() -> GhosttyConfigFiles? {
        defer { launchConfigFiles = nil }
        return launchConfigFiles
    }

    /// What the launch's first config load read.
    public nonisolated enum LaunchConfig: Sendable, Equatable {
        /// The files `main` read: every load uses them until ``GhosttyRuntime/endLaunchConfig()``.
        case memory(GhosttyConfigFiles)
        /// The disk, on the main thread: the read had not ended in time, or it declined.
        case disk
    }

    /// The files every load uses until ``endLaunchConfig()``; nil once it ran, or on the disk path.
    var launchFiles: GhosttyConfigFiles? {
        if case .memory(let files) = launchConfig { files } else { nil }
    }

    /// Ends the launch's use of the files read in `main`: later loads read the disk, so they see every
    /// change. Call it before the config files are watched (``liveReloadConfigFiles``).
    ///
    /// - Returns: What the launch read, so the caller can check it against the disk once the watch is armed;
    ///   nil when it already ended.
    @discardableResult
    public func endLaunchConfig() -> LaunchConfig? {
        defer { launchConfig = nil }
        return launchConfig
    }

    /// Reloads the config from the disk, never from the launch's files: what the person's Reload
    /// Configuration does, so it always applies the files as they are now. Before the watch starts,
    /// the launch then counts as a disk launch, which the watch's start reloads once.
    public func reloadConfigFromDisk() {
        if launchConfig != nil { launchConfig = .disk }
        reloadConfig()
    }

    public var loadedConfigFiles: [String] {
        guard let config else { return [] }
        return Self.loadedFiles(of: config, memory: configMemoryFiles)
    }

    /// The files that can change which Ghostty config is loaded. The finalized
    /// config supplies every file that exists, while these candidates keep a
    /// watch armed for a config created after launch or for a file that wins
    /// precedence when it appears.
    public var liveReloadConfigFiles: [String] {
        var paths = loadedConfigFiles
        if let override = Self.environmentConfigOverride {
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

    /// The files `config` was loaded from: `memory`, the files loaded from memory
    /// (``GhosttyConfigFiles``, which libghostty does not list), then the files
    /// libghostty read itself (all of them on the disk path; on either path the
    /// theme files, which finalize still reads from the disk), once each: the
    /// order libghostty lists when it reads every file.
    nonisolated static func loadedFiles(of config: ghostty_config_t, memory: [String] = []) -> [String] {
        let read = (0..<ghostty_config_loaded_file_count(config)).compactMap { index in
            ghostty_config_loaded_file(config, index).map { String(cString: $0) }
        }
        var seen = Set<String>()
        return (memory + read).filter { seen.insert($0).inserted }
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
