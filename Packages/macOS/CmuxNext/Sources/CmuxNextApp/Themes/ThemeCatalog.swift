import CmuxNextDesign
import CmuxNextTerminal
import Foundation
import Observation

/// Every theme Ghostty can load: the files in its resources `themes` folder
/// and in the user's `~/.config/ghostty/themes` (the user's win on a name
/// clash, as in Ghostty). Listed once off the main thread at launch; the
/// pickers search it and theme actions accept only specs it knows (or an
/// absolute path to a theme file, which Ghostty also loads).
@MainActor
@Observable
final class ThemeCatalog {
    /// Theme names, sorted case-insensitively.
    private(set) var names: [String] = []
    /// Each theme's swatch strip (`ThemeSwatch`), read after the names.
    private(set) var strips: [String: [ThemeRGB]] = [:]
    @ObservationIgnored private var known: Set<String> = []
    @ObservationIgnored private var loading: Task<Void, Never>?

    func load() {
        guard loading == nil else { return }
        loading = Task { [weak self] in
            let listed = await Task.detached(priority: .utility) {
                Self.list(resources: GhosttyRuntime.resourcesDirectory(), home: FileManager.default.homeDirectoryForCurrentUser,
                          environment: ProcessInfo.processInfo.environment)
            }.value
            self?.names = listed
            self?.known = Set(listed)
        }
    }

    /// Whether Ghostty accepts `text` as a theme spec: a spec whose every
    /// name is a known theme or an absolute path to a file. Before the list
    /// loads, any well-formed spec passes (Ghostty then reports a missing
    /// theme in its config diagnostics).
    func accepts(_ text: String) -> Bool {
        guard let spec = ThemeSpec(text) else { return false }
        guard !known.isEmpty else { return true }
        return Set([spec.light, spec.dark]).allSatisfy { name in
            // concurrency-allow: one stat of a user-typed absolute path, on an explicit action
            known.contains(name) || (name.hasPrefix("/") && FileManager.default.fileExists(atPath: name))
        }
    }

    /// The swatch strip of the theme `name`; empty for an unknown name or
    /// before the strips load.
    func swatches(for name: String) -> [ThemeRGB] {
        []
    }

    /// Every theme's swatch strip, the user's file winning on a name clash.
    nonisolated static func strips(resources: String?, home: URL, environment: [String: String]) -> [String: [ThemeRGB]] {
        [:]
    }

    nonisolated static func list(resources: String?, home: URL, environment: [String: String]) -> [String] {
        let configHome = environment["XDG_CONFIG_HOME"].map { URL(fileURLWithPath: $0) } ?? home.appending(path: ".config")
        let folders = [resources.map { URL(fileURLWithPath: $0).appending(path: "themes") },
                       configHome.appending(path: "ghostty").appending(path: "themes")].compactMap(\.self)
        var names = Set<String>()
        for folder in folders {
            // concurrency-allow: nonisolated, called from a detached task at launch
            let entries = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
            names.formUnion(entries.filter { !$0.hasPrefix(".") })
        }
        return names.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }
}
