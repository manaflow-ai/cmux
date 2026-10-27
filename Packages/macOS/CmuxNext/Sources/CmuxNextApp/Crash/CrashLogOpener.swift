import AppKit
import Foundation
import CmuxNextCompatAppKit

/// The one path every "Show Crash Logs" entrypoint takes (the Help menu, the
/// palette, `cmux settings show-crash-logs`, the restart notice): the
/// newest crash log opens in TextEdit. Console (the default app for `.ips`)
/// hides the report text behind its log browser. Finder shows the file only
/// when TextEdit is missing; a folder (no log yet) always opens in Finder.
nonisolated struct CrashLogOpener: Sendable {
    enum Outcome: Equatable, Sendable {
        case textEdit(URL)
        case finder(URL)
    }

    /// The TextEdit app URL, nil when it is not installed.
    var textEditURL: @Sendable () -> URL?
    /// Opens a file with an app.
    var openWith: @Sendable (_ file: URL, _ app: URL) -> Void
    /// Shows a file selected in Finder, or opens a folder.
    var reveal: @Sendable (URL) -> Void

    /// TextEdit on the sealed system volume, where macOS installs it: no Launch Services lookup on the main thread.
    static let systemTextEdit = URL(fileURLWithPath: "/System/Applications/TextEdit.app", isDirectory: true)

    static let system = CrashLogOpener(
        textEditURL: { systemTextEdit },
        openWith: { file, app in
            NSWorkspace.shared.openInBackground([file], withApplicationAt: app)
        },
        reveal: { url in
            if url.hasDirectoryPath {
                NSWorkspace.shared.openInBackground(url)
            } else {
                NSWorkspace.shared.revealInBackground([url])
            }
        }
    )

    @discardableResult
    func show(_ target: URL) -> Outcome {
        if !target.hasDirectoryPath, let app = textEditURL() {
            openWith(target, app)
            return .textEdit(target)
        }
        reveal(target)
        return .finder(target)
    }

    /// What "Show Crash Logs" opens: the previous run's macOS report, else
    /// cmux's own report of it, else the newest macOS report of this
    /// executable, else the newest cmux report, else cmux's report folder.
    static func target(previousSystemLog: URL?, previousReport: URL?, reportDirectory: URL,
                       systemLogs: URL, executable: String) -> URL {
        if let previousSystemLog { return previousSystemLog }
        if let previousReport { return previousReport }
        if let newest = newestFile(in: systemLogs, where: { $0.pathExtension == "ips" && $0.lastPathComponent.hasPrefix(executable + "-") }) {
            return newest
        }
        if let newest = newestFile(in: reportDirectory, where: { $0.pathExtension == "json" }) { return newest }
        return reportDirectory.hasDirectoryPath ? reportDirectory : reportDirectory.appending(path: "", directoryHint: .isDirectory)
    }

    static func newestFile(in folder: URL, where keep: (URL) -> Bool) -> URL? {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return files
            .filter(keep)
            .map { ($0, (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }
            .max { $0.1 < $1.1 }?.0
    }
}
