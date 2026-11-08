public import Foundation

/// Finds other terminals' settings on this Mac and reads them into ``ImportedTerminalSettings``.
///
/// Read-only: nothing here writes to the source terminals' files or preferences.
///
/// ```swift
/// let home = FileManager.default.homeDirectoryForCurrentUser
/// let importer = TerminalImporter(
///     homeDirectory: home,
///     environment: ProcessInfo.processInfo.environment,
///     preferences: SystemTerminalPreferencesReader(homeDirectory: home),
///     files: DiskTerminalConfigFileReader()
/// )
/// let settings = try importer.load(.kitty)
/// ```
public struct TerminalImporter: Sendable {
    private let homeDirectory: URL
    private let environment: [String: String]
    private let preferences: any TerminalPreferencesReading
    private let files: any TerminalConfigFileReading

    /// Creates an importer.
    ///
    /// - Parameters:
    ///   - homeDirectory: The home directory config paths are relative to.
    ///   - environment: Supplies `XDG_CONFIG_HOME`, `KITTY_CONFIG_DIRECTORY` and `WEZTERM_CONFIG_FILE`.
    ///   - preferences: Reads iTerm2 and Terminal preferences domains.
    ///   - files: Reads config files and lists theme directories.
    public init(
        homeDirectory: URL,
        environment: [String: String],
        preferences: any TerminalPreferencesReading,
        files: any TerminalConfigFileReading
    ) {
        self.homeDirectory = homeDirectory
        self.environment = environment
        self.preferences = preferences
        self.files = files
    }

    /// Every source with settings on this Mac, in ``TerminalImportSource`` order.
    public func detect() -> [DetectedTerminal] {
        TerminalImportSource.allCases.compactMap(detect)
    }

    /// Detects one source.
    ///
    /// - Parameter source: The terminal to look for.
    /// - Returns: What was found, or `nil` when the source has no settings here.
    public func detect(_ source: TerminalImportSource) -> DetectedTerminal? {
        switch source {
        case .iTerm2:
            guard let prefs = preferences.preferences(forDomain: "com.googlecode.iterm2"),
                  let profiles = prefs["New Bookmarks"] as? [[String: Any]], !profiles.isEmpty else { return nil }
            let guid = prefs["Default Bookmark Guid"] as? String
            let name = (profiles.first { ($0["Guid"] as? String) == guid } ?? profiles[0])["Name"] as? String
            return .init(source: source, configURL: nil, detail: "default profile \"\(name ?? "Default")\"")
        case .terminalApp:
            guard let prefs = preferences.preferences(forDomain: "com.apple.Terminal"),
                  (try? TerminalAppProfileParser().parse(preferences: prefs)) != nil else { return nil }
            let name = prefs["Default Window Settings"] as? String ?? "Basic"
            return .init(source: source, configURL: nil, detail: "default profile \"\(name)\"")
        case .warp:
            let themes = warpThemes()
            guard !themes.isEmpty else { return nil }
            let names = themes.map(\.lastPathComponent).joined(separator: ", ")
            return .init(source: source, configURL: themes.count == 1 ? themes[0] : nil, detail: "themes: \(names)")
        case .alacritty, .kitty, .wezTerm, .ghostty:
            guard let url = candidateURLs(for: source).first(where: { files.contents(of: $0) != nil }) else { return nil }
            return .init(source: source, configURL: url, detail: abbreviated(url))
        }
    }

    /// Reads a source's settings.
    ///
    /// - Parameters:
    ///   - source: The terminal to read.
    ///   - path: An explicit config file (or Warp theme), overriding detection.
    /// - Returns: The settings.
    /// - Throws: ``TerminalImportError`` when nothing can be read.
    public func load(_ source: TerminalImportSource, path: URL? = nil) throws -> ImportedTerminalSettings {
        switch source {
        case .ghostty:
            throw TerminalImportError.ghosttyAlreadyLoaded
        case .iTerm2:
            guard let prefs = preferences.preferences(forDomain: "com.googlecode.iterm2"),
                  let settings = try? ITerm2ProfileParser().parse(preferences: prefs) else {
                throw TerminalImportError.notFound(source)
            }
            return settings
        case .terminalApp:
            guard let prefs = preferences.preferences(forDomain: "com.apple.Terminal") else {
                throw TerminalImportError.notFound(source)
            }
            do {
                return try TerminalAppProfileParser().parse(preferences: prefs)
            } catch TerminalAppProfileParser.ParseError.builtInProfile(let name) {
                throw TerminalImportError.builtInTerminalProfile(name)
            }
        case .alacritty:
            let url = try configURL(for: source, explicit: path)
            guard let settings = AlacrittyConfigParser(reader: files, homeDirectory: homeDirectory).parse(url: url) else {
                throw TerminalImportError.unreadable(url)
            }
            return settings
        case .kitty:
            let url = try configURL(for: source, explicit: path)
            guard let settings = KittyConfigParser(reader: files, homeDirectory: homeDirectory).parse(url: url) else {
                throw TerminalImportError.unreadable(url)
            }
            return settings
        case .wezTerm:
            let url = try configURL(for: source, explicit: path)
            guard let text = files.contents(of: url) else { throw TerminalImportError.unreadable(url) }
            return WezTermConfigParser().parse(source: text, profileName: url.lastPathComponent)
        case .warp:
            let url: URL
            if let path {
                url = path
            } else {
                let themes = warpThemes()
                guard !themes.isEmpty else { throw TerminalImportError.notFound(source) }
                guard themes.count == 1 else { throw TerminalImportError.warpThemeChoiceNeeded(themes) }
                url = themes[0]
            }
            guard let text = files.contents(of: url) else { throw TerminalImportError.unreadable(url) }
            return WarpThemeParser().parse(source: text, profileName: url.lastPathComponent)
        }
    }

    /// The config paths each file-based source reads, in the source's own lookup order.
    func candidateURLs(for source: TerminalImportSource) -> [URL] {
        let configHome = environment["XDG_CONFIG_HOME"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) }
        let dotConfig = homeDirectory.appendingPathComponent(".config", isDirectory: true)
        let configDirs = [configHome, dotConfig].compactMap { $0 }
        func inConfig(_ relative: String) -> [URL] {
            configDirs.map { $0.appendingPathComponent(relative, isDirectory: false) }
        }
        func inHome(_ relative: String) -> URL {
            homeDirectory.appendingPathComponent(relative, isDirectory: false)
        }
        switch source {
        case .alacritty:
            return inConfig("alacritty/alacritty.toml") + [inHome(".alacritty.toml")]
                + inConfig("alacritty/alacritty.yml") + [inHome(".alacritty.yml")]
        case .kitty:
            let explicit = environment["KITTY_CONFIG_DIRECTORY"].map {
                URL(fileURLWithPath: $0, isDirectory: true).appendingPathComponent("kitty.conf", isDirectory: false)
            }
            return [explicit].compactMap { $0 } + inConfig("kitty/kitty.conf")
                + [inHome("Library/Preferences/kitty/kitty.conf")]
        case .wezTerm:
            let explicit = environment["WEZTERM_CONFIG_FILE"].map { URL(fileURLWithPath: $0, isDirectory: false) }
            return [explicit].compactMap { $0 } + inConfig("wezterm/wezterm.lua") + [inHome(".wezterm.lua")]
        case .ghostty:
            return inConfig("ghostty/config") + inConfig("ghostty/config.ghostty") + [
                inHome("Library/Application Support/com.mitchellh.ghostty/config"),
                inHome("Library/Application Support/com.mitchellh.ghostty/config.ghostty"),
            ]
        case .iTerm2, .terminalApp, .warp:
            return []
        }
    }

    private func configURL(for source: TerminalImportSource, explicit: URL?) throws -> URL {
        if let explicit { return explicit }
        guard let url = candidateURLs(for: source).first(where: { files.contents(of: $0) != nil }) else {
            throw TerminalImportError.notFound(source)
        }
        return url
    }

    private func warpThemes() -> [URL] {
        files.files(in: homeDirectory.appendingPathComponent(".warp/themes", isDirectory: true))
            .filter { ["yaml", "yml"].contains($0.pathExtension.lowercased()) }
    }

    private func abbreviated(_ url: URL) -> String {
        let home = homeDirectory.path
        return url.path.hasPrefix(home + "/") ? "~" + url.path.dropFirst(home.count) : url.path
    }
}
