import Combine
import Foundation
import OSLog
import CmuxSidebarScript

/// Loads, compiles, and updates the user's optional sidebar customization script.
///
/// The sidebar renders rows natively unless `~/.config/cmux/sidebar.lisp` exists
/// and compiles. When it does, `script` is non-nil and each row renders through
/// it; any compile or render fault falls back to the native row, so a broken
/// script can never break the sidebar.
@MainActor
final class SidebarScriptStore: ObservableObject {
    /// The compiled script, or nil when the user has no `sidebar.lisp` (or it
    /// failed to compile).
    @Published private(set) var script: SidebarScript?

    /// The active source text. Non-nil even for a script that failed to compile
    /// so the menu can still report whether it matches a bundled demo.
    @Published private(set) var source: String?

    /// Bumps whenever the active script identity changes. Folded into the row's
    /// equatability so a new script re-renders every row.
    @Published private(set) var version: Int = 0

    private static let logger = Logger(subsystem: "com.manaflow.cmux", category: "SidebarScript")
    private let url: URL

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
        self.url = url
        reload()
    }

    var activeDemoId: String? {
        source.flatMap(SidebarScriptDemo.matchingDemoId(for:))
    }

    var isNativeActive: Bool {
        source == nil
    }

    func reload() {
        guard let source = try? String(contentsOf: url, encoding: .utf8) else {
            setSource(nil, compiledScript: nil)
            return
        }

        load(source: source)
    }

    func useNativeSidebar() {
        do {
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
            setSource(nil, compiledScript: nil)
            Self.logger.info("Disabled custom sidebar.lisp.")
        } catch {
            Self.logger.error("Failed to remove sidebar.lisp: \(String(describing: error), privacy: .public)")
        }
    }

    func applyDemo(_ demo: SidebarScriptDemo) {
        applySource(demo.source, logName: demo.id)
    }

    private func applySource(_ source: String, logName: String) {
        do {
            let compiledScript = try SidebarScript(source: source)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try source.write(to: url, atomically: true, encoding: .utf8)
            setSource(source, compiledScript: compiledScript)
            Self.logger.info("Applied sidebar Lisp demo '\(logName, privacy: .public)' (\(source.count) chars).")
        } catch {
            Self.logger.error("Failed to apply sidebar Lisp demo '\(logName, privacy: .public)': \(String(describing: error), privacy: .public)")
        }
    }

    private func load(source: String) {
        do {
            let compiledScript = try SidebarScript(source: source)
            setSource(source, compiledScript: compiledScript)
            Self.logger.info("Loaded custom sidebar.lisp (\(source.count) chars).")
        } catch {
            setSource(source, compiledScript: nil)
            Self.logger.error("sidebar.lisp failed to compile: \(String(describing: error), privacy: .public)")
        }
    }

    private func setSource(_ source: String?, compiledScript: SidebarScript?) {
        self.source = source
        script = compiledScript
        version = source?.hashValue ?? 0
    }
}
