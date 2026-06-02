import Foundation
import OSLog
import CmuxSidebarScript

/// Loads and compiles the user's optional sidebar customization script.
///
/// The sidebar renders rows natively unless `~/.config/cmux/sidebar.lisp` exists
/// and compiles. When it does, `script` is non-nil and each row renders through
/// it; any compile or render fault falls back to the native row, so a broken
/// script can never break the sidebar.
///
/// The script is compiled once when the store is created (i.e. at sidebar
/// construction). Editing the file takes effect on the next app launch. Live
/// reload is a deliberate follow-up.
@MainActor
final class SidebarScriptStore {
    /// The compiled script, or nil when the user has no `sidebar.lisp` (or it
    /// failed to compile).
    let script: SidebarScript?

    /// Bumps whenever the active script identity changes. Folded into the row's
    /// equatability so a new script re-renders every row.
    let version: Int

    private static let logger = Logger(subsystem: "com.manaflow.cmux", category: "SidebarScript")

    /// Logs a per-row render failure. Called from the sidebar row when a script
    /// faults so the row can fall back to native rendering.
    static func logRenderFailure(_ error: Error) {
        logger.error("sidebar.lisp render failed: \(String(describing: error), privacy: .public)")
    }

    /// The default path users edit to customize the sidebar.
    nonisolated static var scriptURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/cmux/sidebar.lisp")
    }

    init(url: URL = SidebarScriptStore.scriptURL) {
        guard let source = try? String(contentsOf: url, encoding: .utf8) else {
            script = nil
            version = 0
            return
        }
        do {
            script = try SidebarScript(source: source)
            // A within-run identity for the compiled script. `hashValue` is only
            // compared within this process, where it is stable.
            version = source.hashValue
            Self.logger.info("Loaded custom sidebar.lisp (\(source.count) chars).")
        } catch {
            script = nil
            version = 0
            Self.logger.error("sidebar.lisp failed to compile: \(String(describing: error), privacy: .public)")
        }
    }
}
