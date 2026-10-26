public import CmuxNextDesign
public import CmuxNextWakeups
public import Foundation
import GhosttyNextKit

/// The user's Ghostty config files read into memory off the main thread, so the terminal runtime's
/// first load reads no file on the main thread (`ghostty_config_load_string`; p08-startup-026).
///
/// The app reads them on a launch lane from the top of `main` (``prefetch(on:)``):
/// Chrome's UI thread never blocks on a file (`base/threading/thread_restrictions.h`, `ScopedBlockingCall`),
/// and cmux goes past Chrome's Local State read on the UI thread (`chrome/browser/chrome_browser_main.cc`)
/// by reading before the main thread needs the bytes. ``read(_:reader:)`` takes the files libghostty's own
/// load takes, in its order: `Config.loadDefaultFiles` (or the `CMUX_NEXT_GHOSTTY_CONFIG` file), classic
/// cmux's layer, then `Config.loadRecursiveFiles`' `config-file` includes, breadth first
/// (ghostty-next `src/config/Config.zig`). Whenever libghostty would do more than read plain files (no
/// config at all, where it writes its template; an empty, unreadable or non-regular file; an include
/// cycle, a missing required include, a `config-file` reset), the read gives nil and the load reads the
/// disk as before, so both paths make the same config, diagnostics and loaded files.
///
/// ```swift
/// if let files = GhosttyConfigFiles.read(.current()) { files.load(into: config) }   // else the disk path
/// ```
public nonisolated struct GhosttyConfigFiles: Sendable, Equatable {
    /// One file's path, as libghostty names it (diagnostics, key sources, loaded files), and its bytes.
    public nonisolated struct File: Sendable, Equatable {
        public let path: String
        public let contents: Data
    }

    /// Where libghostty looks for the user's files.
    public nonisolated struct Locations: Sendable, Equatable {
        /// `CMUX_NEXT_GHOSTTY_CONFIG`: this file alone, with its includes.
        public var override: String?
        /// Ghostty's default files in its load order (XDG `config`, `config.ghostty`; App Support
        /// `config`, `config.ghostty`), present or not.
        public var defaults: [String]
        /// Classic cmux's layer, when one is present (``GhosttyRuntime/classicConfigPath(applicationSupportDirectory:bundleIdentifier:)``).
        public var classic: String?
        /// The home directory a `~/` include expands to (Ghostty's `homedir.home`); nil when there is none.
        public var home: String?

        public init(override: String? = nil, defaults: [String] = [], classic: String? = nil, home: String?) {
            (self.override, self.defaults, self.classic, self.home) = (override, defaults, classic, home)
        }

        /// This process's locations, as libghostty and the runtime's disk path
        /// find them. It asks the file system for App Support and the classic layer: call it off the main thread.
        public static func current(environment: [String: String] = ProcessInfo.processInfo.environment,
                                   bundleIdentifier: String? = Bundle.main.bundleIdentifier) -> Locations {
            // Ghostty's `homedir.home`: HOME first, then the account's home directory.
            let home = environment["HOME"] ?? FileManager.default.homeDirectoryForCurrentUser.path
            if let override = environment[GhosttyRuntime.configOverrideKey], !override.isEmpty {
                return Locations(override: override, home: home)
            }
            // `xdg.config`: XDG_CONFIG_HOME when set and not empty, else ~/.config.
            let xdgRoot = environment["XDG_CONFIG_HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? GhosttyConfigFiles.joined(home, ".config")
            let xdg = GhosttyConfigFiles.joined(xdgRoot, "ghostty")
            var defaults = [GhosttyConfigFiles.joined(xdg, "config"), GhosttyConfigFiles.joined(xdg, "config.ghostty")]
            // `macos.appSupportDir`: the user's App Support folder and Ghostty's bundle ID; classic cmux's layer
            // by the URL the disk path names it with (`GhosttyRuntime.loadDefaultFiles`).
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            if let support {
                let native = GhosttyConfigFiles.joined(support.path, "com.mitchellh.ghostty")
                defaults += [GhosttyConfigFiles.joined(native, "config"), GhosttyConfigFiles.joined(native, "config.ghostty")]
            }
            let classic = support.flatMap { GhosttyRuntime.classicConfigPath(applicationSupportDirectory: $0, bundleIdentifier: bundleIdentifier) }
            return Locations(defaults: defaults, classic: classic, home: home)
        }
    }

    /// The files in load order: the top-level files, then the includes.
    public let files: [File]

    /// Starts reading the user's files on `work`'s files lane (the app's `main`); the app hands the result to
    /// the terminal runtime before its first load (``GhosttyRuntime/launchConfigFiles``), never waiting for it.
    ///
    /// - Parameter work: The app's blocking-work lanes.
    /// - Returns: The read.
    public static func prefetch(on work: BackgroundWork) -> LaunchRead<GhosttyConfigFiles?> {
        LaunchRead(on: work) { GhosttyConfigFiles.read(.current()) }
    }

    /// A file larger than this is left to the disk path.
    static let maximumFileBytes = 4 << 20
    /// More files than this (includes included) are left to the disk path.
    static let maximumFiles = 64

    /// Reads the files at `locations` (blocking: call it off the main thread).
    ///
    /// - Parameters:
    ///   - locations: Where libghostty looks.
    ///   - reader: The file system (tests pass their own).
    /// - Returns: The files; nil when the load must read the disk itself (see the type's discussion).
    public static func read(_ locations: Locations, reader: Reader = .disk) -> GhosttyConfigFiles? {
        var files: [File] = []
        // `Config.loadFile` and `loadOptionalFile`: a missing default file is skipped, an empty one is an error.
        func top(_ path: String, optional: Bool) -> Bool {
            guard path.hasPrefix("/") else { return false }  // libghostty asserts an absolute path
            switch reader.entry(path) {
            case .missing: return optional
            case .file(let contents) where !contents.isEmpty:
                files.append(File(path: path, contents: contents))
                return true
            default: return false
            }
        }
        if let override = locations.override {
            guard top(override, optional: false) else { return nil }
        } else {
            for path in locations.defaults { guard top(path, optional: true) else { return nil } }
            // No default file: libghostty writes its template, which only the disk path does.
            guard !files.isEmpty else { return nil }
            if let classic = locations.classic { guard top(classic, optional: false) else { return nil } }
        }
        // `Config.loadRecursiveFiles`: every top-level file's `config-file` values, then each include's, in order.
        var queue: [Include] = []
        for file in files {
            guard let found = includes(in: file.contents, of: file.path, home: locations.home, reader: reader) else { return nil }
            queue += found
        }
        var included = Set<String>()
        var next = 0
        while next < queue.count {
            let include = queue[next]
            next += 1
            // libghostty reports a second include of one path as a cycle.
            guard included.insert(include.path).inserted, files.count < maximumFiles else { return nil }
            switch reader.entry(include.path) {
            case .missing where include.optional: continue
            case .file(let contents):
                files.append(File(path: include.path, contents: contents))
                guard let found = includes(in: contents, of: include.path, home: locations.home, reader: reader) else { return nil }
                queue += found
            default: return nil
            }
        }
        return GhosttyConfigFiles(files: files)
    }

    /// Loads every file's bytes into `config` under its path, in order (no file is read).
    func load(into config: ghostty_config_t) {
        for file in files {
            file.contents.withUnsafeBytes { bytes in
                guard let base = bytes.baseAddress?.assumingMemoryBound(to: CChar.self) else { return }
                ghostty_config_load_string(config, base, UInt(bytes.count), file.path)
            }
        }
    }

    /// `std.fs.path.join` of two parts: one separator between them.
    static func joined(_ head: String, _ tail: String) -> String {
        if head.isEmpty { return tail }
        switch (head.hasSuffix("/"), tail.hasPrefix("/")) {
        case (true, true): return head + tail.dropFirst()
        case (false, false): return head + "/" + tail
        default: return head + tail
        }
    }
}
