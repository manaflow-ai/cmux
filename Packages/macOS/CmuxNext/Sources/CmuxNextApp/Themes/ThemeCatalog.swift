import CmuxNextDesign
import CmuxNextTerminal
import Foundation
import Observation

/// Every theme Ghostty can load: the files in its resources `themes` folder
/// and in the user's `~/.config/ghostty/themes` (the user's win on a name
/// clash, as in Ghostty). Listed once off the main thread at launch; the
/// pickers search it and theme actions accept only specs it knows (or an
/// absolute path to a theme file, which Ghostty also loads). Each theme's
/// swatch strip (R98) is read from its file in a second off-main pass and
/// kept here, so pickers draw strips without reading files.
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
            // The strips after the names, so pickers list themes first; a
            // strip-less row draws its symbol until then.
            let strips = await Task.detached(priority: .utility) {
                Self.strips(resources: GhosttyRuntime.resourcesDirectory(), home: FileManager.default.homeDirectoryForCurrentUser,
                            environment: ProcessInfo.processInfo.environment)
            }.value
            self?.strips = strips
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
        strips[name] ?? []
    }

    /// Every theme's swatch strip, the user's file winning on a name clash.
    nonisolated static func strips(resources: String?, home: URL, environment: [String: String]) -> [String: [ThemeRGB]] {
        var strips: [String: [ThemeRGB]] = [:]
        // Shipped themes first, so the user's folder replaces a clash.
        for (name, file) in themeFiles(resources: resources, home: home, environment: environment) {
            // concurrency-allow: nonisolated, called from a detached task at launch
            guard let data = try? Data(contentsOf: file, options: .mappedIfSafe), data.count <= maximumThemeFileBytes else { continue }
            strips[name] = ThemeSwatch.strip(themeFile: String(decoding: data, as: UTF8.self))
        }
        return strips
    }

    nonisolated static func list(resources: String?, home: URL, environment: [String: String]) -> [String] {
        Set(themeFiles(resources: resources, home: home, environment: environment).map(\.name))
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    /// A theme file larger than this is not read for a strip (a real one is
    /// under 2 KB).
    nonisolated static let maximumThemeFileBytes = 64 * 1024

    /// Every theme file: the resources folder's, then the user's.
    private nonisolated static func themeFiles(resources: String?, home: URL,
                                               environment: [String: String]) -> [(name: String, file: URL)] {
        let configHome = environment["XDG_CONFIG_HOME"].map { URL(fileURLWithPath: $0) } ?? home.appending(path: ".config")
        let folders = [resources.map { URL(fileURLWithPath: $0).appending(path: "themes") },
                       configHome.appending(path: "ghostty").appending(path: "themes")].compactMap(\.self)
        return folders.flatMap { folder in
            // concurrency-allow: nonisolated, called from a detached task at launch
            let entries = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
            return entries.filter { !$0.hasPrefix(".") }.sorted().map { (name: $0, file: folder.appending(path: $0)) }
        }
    }
}
