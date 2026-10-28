import CmuxNextCompat
public import Foundation
import os

/// The file whose absence makes a launch the app's first (p08-startup-108). Chrome's `first_run::IsChromeFirstRun`
/// is the absence of its sentinel, which `first_run::CreateSentinelIfNeeded` writes once and nothing removes
/// (chrome/browser/first_run/first_run.cc); a session record such as the run marker's `run.json` is no first-run
/// signal, since a normal quit removes it.
///
/// ```swift
/// let first = FirstRunSentinel(directory: markerFolder).isMissing()  // on the launch read's files lane
/// FirstRunSentinel(directory: markerFolder).write()                  // once the first launch made its marker
/// ```
public nonisolated struct FirstRunSentinel: Sendable, Equatable {
    /// The sentinel file, `first-run` in its folder.
    public let url: URL

    /// The sentinel in `directory` (the app's run marker folder; tests pass their own).
    public init(directory: URL) {
        url = directory.appending(path: "first-run")
    }

    /// Whether no launch wrote the sentinel, so this launch is the first. Blocking: on a files lane.
    public func isMissing() -> Bool {
        !FileManager.checked.fileExists(atPath: url.path)
    }

    /// Writes the sentinel (empty); false, and logged, when it could not be written. Blocking: on a files lane.
    @discardableResult
    public func write() -> Bool {
        let written = FileManager.checked.createFile(atPath: url.path, contents: Data())
        if !written { Logger(subsystem: "com.cmuxterm.app.next", category: "launch").error("first-run sentinel not written") }
        return written
    }
}
