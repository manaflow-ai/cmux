import Foundation

/// Where a build keeps its Chief. Today every tag has its own: its own mux
/// home, its own acpmux and its own daemon session, so each build shows its
/// own Chief history (the behavior the tests in ChiefHomeTests reject).
nonisolated struct ChiefHome: Sendable, Equatable {
    let root: URL
    let isolated: Bool
    let acpmuxHome: URL
    let session: String

    var muxHome: URL { root }
    var daemonStateDirectory: URL { root.appendingPathComponent("tui", isDirectory: true) }

    static func resolve(tag: String?, environment: [String: String] = ProcessInfo.processInfo.environment,
                        userHome: URL = FileManager.default.homeDirectoryForCurrentUser) -> ChiefHome {
        let base = userHome.appendingPathComponent(".cmux/mux", isDirectory: true)
        let root: URL
        if let custom = environment["CMUX_NEXT_MUX_HOME"], !custom.isEmpty {
            root = URL(fileURLWithPath: custom, isDirectory: true)
        } else if let tag, !tag.isEmpty {
            root = base.appendingPathComponent("tags/\(tag)", isDirectory: true)
        } else {
            root = base
        }
        let acpmux = tag.map { userHome.appendingPathComponent(".acpmux/tags/\($0)", isDirectory: true) }
            ?? userHome.appendingPathComponent(".acpmux", isDirectory: true)
        return ChiefHome(root: root, isolated: false, acpmuxHome: acpmux, session: (try? DaemonLauncherName.session(tag)) ?? "cmux-app")
    }

    static func sessionName(root: URL) -> String { "cmux-app" }
}

enum DaemonLauncherName {
    static func session(_ tag: String?) throws -> String { tag.map { "cmux-app-\($0)" } ?? "cmux-app" }
}
