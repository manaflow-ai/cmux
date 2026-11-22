#if CMUX_UI_LAYER_PREVIEW
public import AppKit
public import CmuxNextDesign
import CmuxNextCompat
import CmuxNextSettings
public import CmuxTheme

/// The look of the person's installed cmux NEXT (nightly, DEV or release), read the way the app
/// reads it, so the UI host's windows wear the same theme, accent and background without
/// Ghostty, a daemon or the app itself.
///
/// Every channel shares `~/.config/cmux/cmux-next.json` (`CmuxConfigFile.defaultURL`), so the
/// host parses that file with the app's own `CmuxConfigSnapshot`: `appearance.theme`,
/// `appearance.accent`, `appearance.themeEdits`, the window Opacity and Material, and
/// `appearance.background`. The terminal theme under it comes from the Ghostty config files the
/// app layers (Ghostty's own, then classic cmux's layer), and theme files from the user's
/// themes folder, an installed cmux or Ghostty app, or the checkout's `Resources/ghostty/themes`.
///
/// ```swift
/// let look = await UiLayerAppLook.loadInBackground(isDark: true)
/// look.apply(to: .app)
/// ```
public nonisolated struct UiLayerAppLook: Equatable, Sendable {
    /// The chrome's colors, opacity and blur, as `ThemeBridge.input` would build them.
    public var input: ThemeInput
    /// `appearance.accent`.
    public var accent: ThemeAccent
    /// `appearance.background`: the picture behind the window, nil for none.
    public var backdrop: BackdropSelection?
    /// The theme file the colors came from, nil for Ghostty's built-in colors.
    public var themeName: String?
    /// The files read, for the host's status line.
    public var sources: [String]

    /// The app's default pair (`GhosttyRuntime.defaultThemeSpec`), loaded under the person's files.
    public static let defaultThemeSpec = "light:Apple System Colors Light,dark:Apple System Colors"

    /// Reads the look off the main thread (file reads; the main actor never blocks on them).
    @MainActor public static func loadInBackground(isDark: Bool) async -> UiLayerAppLook {
        await Task.detached(priority: .userInitiated) { load(isDark: isDark) }.value
    }

    /// Reads the look now, on the caller's thread: never call it on the main actor.
    ///
    /// - Parameters:
    ///   - isDark: The window appearance, which picks a light/dark pair's side.
    ///   - home: The account's home (tests pass a temporary one).
    ///   - environment: `CMUX_NEXT_CONFIG_FILE`, `XDG_CONFIG_HOME` and `CMUX_UI_LAYER_THEMES`
    ///     (extra theme folders, colon-separated; launch.sh passes the checkout's).
    ///   - applicationFolders: Where installed apps are looked for.
    public static func load(
        isDark: Bool,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        applicationFolders: [URL]? = nil
    ) -> UiLayerAppLook {
        var sources: [String] = []
        let configURL = CmuxConfigFile.defaultURL(home: home, environment: environment)
        var snapshot = CmuxConfigSnapshot.empty
        if let text = try? String(blockingContentsOf: configURL, encoding: .utf8), let root = try? JSONC.parse(text) {
            // Only the appearance keys are read, so densities and metrics need no validation.
            snapshot = CmuxConfigSnapshot.parse(root, validDensities: [], validMetrics: [],
                                                configDirectory: configURL.deletingLastPathComponent())
            sources.append(configURL.path)
        }

        var ghostty = UiLayerGhosttyConfig(themeSpec: defaultThemeSpec)
        for url in ghosttyConfigURLs(home: home, environment: environment) {
            guard let text = try? String(blockingContentsOf: url, encoding: .utf8) else { continue }
            ghostty.read(text)
            sources.append(url.path)
        }
        // `appearance.theme` is applied over the Ghostty config, as the app's override does.
        if let appTheme = snapshot.appTheme { ghostty.themeSpec = appTheme }

        let folders = themeFolders(home: home, environment: environment,
                                   applicationFolders: applicationFolders ?? defaultApplicationFolders(home: home))
        let themeName = ThemeSpec(ghostty.themeSpec)?.name(isDark: isDark) ?? ghostty.themeSpec
        let themeFile = themeFile(named: themeName, in: folders)
        if let themeFile { sources.append(themeFile.url.path) }

        var input = ghostty.input(over: themeFile?.colors)
        let resolved = snapshot.windowBackground.resolved(backgroundOpacity: input.backgroundOpacity,
                                                         backgroundBlur: input.backgroundBlur)
        input.backgroundOpacity = resolved.backgroundOpacity
        input.backgroundBlur = resolved.backgroundBlur
        input.accentColor = snapshot.themeEdits.accent(for: themeName).flatMap { ThemeRGB(cssHex: $0) } ?? themeFile?.colors.accent
        return UiLayerAppLook(input: input, accent: snapshot.accent, backdrop: snapshot.backdropSelection,
                              themeName: themeFile == nil ? nil : themeName, sources: sources)
    }

    /// Gives `scope` (the app scope the real views read) this look: colors, accent and picture.
    @MainActor public func apply(to scope: ThemeScope) {
        scope.store.setAccent(accent)
        scope.store.apply(input)
        scope.setBackdropSelection(backdrop)
    }

    /// Every file `load` reads, existing or not, so a watcher sees a first save.
    public static func watchedFiles(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [URL] {
        [CmuxConfigFile.defaultURL(home: home, environment: environment)] + ghosttyConfigURLs(home: home, environment: environment)
    }

    /// Ghostty's default files, then classic cmux's layer for the stable and nightly channels
    /// (`GhosttyRuntime.loadDefaultFiles`), in the order the app loads them.
    static func ghosttyConfigURLs(home: URL, environment: [String: String]) -> [URL] {
        let configHome = environment["XDG_CONFIG_HOME"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
            ?? home.appending(path: ".config")
        let support = home.appending(path: "Library/Application Support")
        return [
            configHome.appending(path: "ghostty/config"),
            configHome.appending(path: "ghostty/config.ghostty"),
            support.appending(path: "com.mitchellh.ghostty/config"),
            support.appending(path: "com.mitchellh.ghostty/config.ghostty"),
            support.appending(path: "com.cmuxterm.app/config.ghostty"),
            support.appending(path: "com.cmuxterm.app/config"),
        ]
    }

    static func defaultApplicationFolders(home: URL) -> [URL] {
        [URL(fileURLWithPath: "/Applications"), home.appending(path: "Applications")]
    }

    /// Theme folders, first match wins: `CMUX_UI_LAYER_THEMES`, the user's Ghostty themes, every
    /// installed cmux app (nightly first), then Ghostty.app.
    static func themeFolders(home: URL, environment: [String: String], applicationFolders: [URL]) -> [URL] {
        var folders = (environment["CMUX_UI_LAYER_THEMES"] ?? "").split(separator: ":").map { URL(fileURLWithPath: String($0)) }
        let configHome = environment["XDG_CONFIG_HOME"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
            ?? home.appending(path: ".config")
        folders.append(configHome.appending(path: "ghostty/themes"))
        var cmuxApps: [URL] = []
        var ghosttyApps: [URL] = []
        for folder in applicationFolders {
            let names = (try? FileManager.checked.contentsOfDirectory(atPath: folder.path)) ?? []
            for name in names where name.hasSuffix(".app") {
                let lower = name.lowercased()
                if lower.contains("cmux") { cmuxApps.append(folder.appending(path: name)) }
                if lower.hasPrefix("ghostty") { ghosttyApps.append(folder.appending(path: name)) }
            }
        }
        cmuxApps.sort { lhs, rhs in
            let l = lhs.lastPathComponent.lowercased().contains("nightly")
            let r = rhs.lastPathComponent.lowercased().contains("nightly")
            return l != r ? l : lhs.lastPathComponent < rhs.lastPathComponent
        }
        folders += (cmuxApps + ghosttyApps).map { $0.appending(path: "Contents/Resources/ghostty/themes") }
        return folders
    }

    /// A theme by name (or absolute path, as Ghostty takes it) in the first folder that has it.
    static func themeFile(named name: String, in folders: [URL]) -> (url: URL, colors: ThemeFileColors)? {
        let candidates = name.hasPrefix("/") ? [URL(fileURLWithPath: name)] : folders.map { $0.appending(path: name) }
        for url in candidates {
            guard let text = try? String(blockingContentsOf: url, encoding: .utf8),
                  let colors = ThemeFileColors(name: url.lastPathComponent, themeFile: text) else { continue }
            return (url, colors)
        }
        return nil
    }
}

/// The few Ghostty config keys the chrome derives from, read line by line in file order (a
/// later line wins, as in Ghostty): `theme`, the colors, `background-opacity` and
/// `background-blur`. Colors set in the config win over the theme file's.
nonisolated struct UiLayerGhosttyConfig: Equatable {
    var themeSpec: String
    var colors: [String: ThemeRGB] = [:]
    var palette: [Int: ThemeRGB] = [:]
    var backgroundOpacity: Double = 1
    var backgroundBlur: Int = 0

    mutating func read(_ text: String) {
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#"), let equals = line.firstIndex(of: "=") else { continue }
            let key = line[..<equals].trimmingCharacters(in: .whitespaces)
            var value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") { value = String(value.dropFirst().dropLast()) }
            switch key {
            case "theme" where !value.isEmpty:
                themeSpec = value
            case "background", "foreground", "selection-background", "selection-foreground", "cursor-color":
                if let color = ThemeRGB(cssHex: value) { colors[key] = color }
            case "palette":
                let parts = value.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                if parts.count == 2, let index = Int(parts[0]), (0..<16).contains(index), let color = ThemeRGB(cssHex: parts[1]) {
                    palette[index] = color
                }
            case "background-opacity":
                if let opacity = Double(value) { backgroundOpacity = min(max(opacity, 0), 1) }
            case "background-blur":
                backgroundBlur = Self.blur(value) ?? backgroundBlur
            default:
                continue
            }
        }
    }

    /// `background-blur` in Ghostty's C encoding: 0 off, > 0 radius, -1/-2 macOS glass.
    static func blur(_ value: String) -> Int? {
        switch value {
        case "false": 0
        case "true": 20
        case "macos-glass-regular": -1
        case "macos-glass-clear": -2
        default: Int(value).map { max($0, 0) }
        }
    }

    /// The theme input: the theme file's colors with the config's own over them, else Ghostty's
    /// built-in colors.
    func input(over theme: ThemeFileColors?) -> ThemeInput {
        let fallback = ThemeInput.ghosttyDefault
        let palette = (0..<16).map { index in
            self.palette[index] ?? theme?.palette[index] ?? fallback.palette[index]
        }
        return ThemeInput(
            background: colors["background"] ?? theme?.background ?? fallback.background,
            foreground: colors["foreground"] ?? theme?.foreground ?? fallback.foreground,
            palette: palette,
            selectionBackground: colors["selection-background"] ?? theme?.selectionBackground,
            selectionForeground: colors["selection-foreground"] ?? theme?.selectionForeground,
            cursor: colors["cursor-color"] ?? theme?.cursorColor,
            backgroundOpacity: backgroundOpacity,
            backgroundBlur: backgroundBlur
        )
    }
}
#endif
