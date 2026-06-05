public import Foundation

/// The per-user directory that holds cmux's control-plane runtime state: the
/// control socket, its `last-socket-path` marker files, the socket password, and
/// the cached remote daemon binaries.
///
/// ## Why not Application Support
///
/// These files are read and written by **two separately code-signed binaries** —
/// the cmux app (bundle id `com.cmuxterm.app`) and the standalone `cmux` CLI
/// installed at `/usr/local/bin/cmux`. On macOS Sequoia, a non-sandboxed process
/// that reaches into another app's data under `~/Library/Application Support`,
/// `~/Library/Containers`, or `~/Library/Group Containers` triggers the
/// "<app> would like to access data from other apps" TCC ("App Data") prompt.
/// The CLI touches the control socket and the socket password on **every** agent
/// session-start and session-stop hook, so keeping those files in Application
/// Support made the prompt fire constantly
/// (https://github.com/manaflow-ai/cmux/issues/5146).
///
/// This directory therefore resolves to `~/.local/state/cmux`, a plain dotfolder
/// macOS does **not** treat as protected app data. It is the sibling of the
/// existing `~/.local/state/cmux/crash` breadcrumb directory.
///
/// ```swift
/// // The stable control socket; app and CLI agree on the same path by passing
/// // the real account home (`FileManager.default.homeDirectoryForCurrentUser`):
/// let home = FileManager.default.homeDirectoryForCurrentUser
/// let socket = CmuxStateDirectory.url(homeDirectory: home).appendingPathComponent("cmux.sock")
/// ```
public enum CmuxStateDirectory {
    /// The directory name segment under `~/.local/state` (and the legacy name
    /// under `~/Library/Application Support`).
    public static let directoryName = "cmux"

    /// The cmux state directory: `<home>/.local/state/cmux`.
    ///
    /// The home directory is injected (no ambient `FileManager.default` default)
    /// so this stays a pure, testable function with no hidden global state.
    /// Composition roots pass `FileManager.default.homeDirectoryForCurrentUser`,
    /// which resolves the real account home independently of the `HOME`
    /// environment variable, so the app and CLI always agree on the path even
    /// when a shell overrides `HOME`.
    ///
    /// - Parameter homeDirectory: The user's home directory.
    /// - Returns: The state directory URL (its parents are created on first write
    ///   by the socket listener, marker writer, and password store).
    public static func url(homeDirectory: URL) -> URL {
        homeDirectory
            .appendingPathComponent(".local", isDirectory: true)
            .appendingPathComponent("state", isDirectory: true)
            .appendingPathComponent(directoryName, isDirectory: true)
    }

    /// The legacy Application Support control directory
    /// (`~/Library/Application Support/cmux`).
    ///
    /// Retained only so the app can migrate persistent files (the socket
    /// password) out of TCC-protected storage on launch. New reads and writes go
    /// through ``url(homeDirectory:)``; nothing on the CLI hook path should touch
    /// this location. The `FileManager` is injected (no ambient default) to keep
    /// the seam explicit for tests and alternate callers.
    ///
    /// - Parameter fileManager: Used to resolve Application Support.
    /// - Returns: The legacy directory, or `nil` when Application Support cannot
    ///   be resolved.
    public static func legacyApplicationSupportURL(fileManager: FileManager) -> URL? {
        fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent(directoryName, isDirectory: true)
    }
}
