import Combine
import Foundation

@MainActor
final class KeyboardShortcutSettingsObserver: ObservableObject {
    static let shared = KeyboardShortcutSettingsObserver()

    @Published private(set) var revision: UInt64 = 0

    private var cancellable: AnyCancellable?

    private init(notificationCenter: NotificationCenter = .default) {
        cancellable = notificationCenter.publisher(for: KeyboardShortcutSettings.didChangeNotification)
            .sink { [weak self] _ in
                self?.revision &+= 1
            }
    }
}

final class KeyboardShortcutSettingsFileStore {
    static let shared = KeyboardShortcutSettingsFileStore()

    private static let releaseBundleIdentifier = "com.cmuxterm.app"

    static var defaultPrimaryPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return (home as NSString).appendingPathComponent(".config/cmux/settings.json")
    }

    static var defaultFallbackPath: String? {
        guard let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            return nil
        }
        return appSupport
            .appendingPathComponent(releaseBundleIdentifier, isDirectory: true)
            .appendingPathComponent("settings.json", isDirectory: false)
            .path
    }

    private let primaryPath: String
    private let fallbackPath: String?
    private let fileManager: FileManager
    private let stateLock = NSLock()
    private var primaryWatcher: ShortcutSettingsFileWatcher?
    private var fallbackWatcher: ShortcutSettingsFileWatcher?

    private var shortcutsByAction: [KeyboardShortcutSettings.Action: StoredShortcut] = [:]
    private(set) var activeSourcePath: String?

    init(
        primaryPath: String = KeyboardShortcutSettingsFileStore.defaultPrimaryPath,
        fallbackPath: String? = KeyboardShortcutSettingsFileStore.defaultFallbackPath,
        fileManager: FileManager = .default,
        startWatching: Bool = true
    ) {
        self.primaryPath = primaryPath
        self.fallbackPath = fallbackPath
        self.fileManager = fileManager
        reload()
        guard startWatching else { return }

        primaryWatcher = ShortcutSettingsFileWatcher(path: primaryPath, fileManager: fileManager) { [weak self] in
            DispatchQueue.main.async {
                self?.reload()
            }
        }
        if let fallbackPath {
            fallbackWatcher = ShortcutSettingsFileWatcher(path: fallbackPath, fileManager: fileManager) { [weak self] in
                DispatchQueue.main.async {
                    self?.reload()
                }
            }
        }
    }

    deinit {
        primaryWatcher?.stop()
        fallbackWatcher?.stop()
    }

    func reload() {
        let previousShortcuts = synchronized { shortcutsByAction }
        let previousActiveSourcePath = synchronized { activeSourcePath }
        let resolved = resolveShortcuts()
        synchronized {
            shortcutsByAction = resolved.shortcuts
            activeSourcePath = resolved.path
        }

        if previousShortcuts != resolved.shortcuts || previousActiveSourcePath != resolved.path {
            KeyboardShortcutSettings.notifySettingsFileDidChange()
        }
    }

    func override(for action: KeyboardShortcutSettings.Action) -> StoredShortcut? {
        synchronized { shortcutsByAction[action] }
    }

    func isManagedByFile(_ action: KeyboardShortcutSettings.Action) -> Bool {
        synchronized { shortcutsByAction[action] != nil }
    }

    private func synchronized<T>(_ body: () -> T) -> T {
        stateLock.lock()
        defer { stateLock.unlock() }
        return body()
    }

    private func resolveShortcuts() -> (path: String?, shortcuts: [KeyboardShortcutSettings.Action: StoredShortcut]) {
        switch loadShortcuts(at: primaryPath) {
        case .parsed(let shortcuts):
            return (primaryPath, shortcuts)
        case .invalid:
            return (primaryPath, [:])
        case .missing:
            break
        }

        guard let fallbackPath else {
            return (nil, [:])
        }

        switch loadShortcuts(at: fallbackPath) {
        case .parsed(let shortcuts):
            return (fallbackPath, shortcuts)
        case .invalid:
            return (fallbackPath, [:])
        case .missing:
            return (nil, [:])
        }
    }

    private enum LoadResult {
        case missing
        case invalid
        case parsed([KeyboardShortcutSettings.Action: StoredShortcut])
    }

    private func loadShortcuts(at path: String) -> LoadResult {
        guard fileManager.fileExists(atPath: path) else {
            return .missing
        }
        guard let data = fileManager.contents(atPath: path),
              !data.isEmpty else {
            return .invalid
        }

        do {
            let file = try JSONDecoder().decode(KeyboardShortcutSettingsFile.self, from: data)
            return .parsed(parseShortcutBindings(file.shortcuts ?? [:], sourcePath: path))
        } catch {
            NSLog("[KeyboardShortcutSettings] parse error at %@: %@", path, String(describing: error))
            return .invalid
        }
    }

    private func parseShortcutBindings(
        _ bindings: [String: KeyboardShortcutBindingDefinition],
        sourcePath: String
    ) -> [KeyboardShortcutSettings.Action: StoredShortcut] {
        var parsed: [KeyboardShortcutSettings.Action: StoredShortcut] = [:]

        for (rawAction, definition) in bindings {
            guard let action = KeyboardShortcutSettings.Action(rawValue: rawAction) else {
                NSLog("[KeyboardShortcutSettings] ignoring unknown shortcut action '%@' in %@", rawAction, sourcePath)
                continue
            }
            guard let shortcut = parseShortcutBinding(definition, for: action) else {
                NSLog(
                    "[KeyboardShortcutSettings] ignoring invalid shortcut binding for '%@' in %@",
                    rawAction,
                    sourcePath
                )
                continue
            }
            parsed[action] = shortcut
        }

        return parsed
    }

    private func parseShortcutBinding(
        _ definition: KeyboardShortcutBindingDefinition,
        for action: KeyboardShortcutSettings.Action
    ) -> StoredShortcut? {
        let shortcut: StoredShortcut?
        switch definition {
        case .single(let strokeText):
            shortcut = parseStoredShortcut(strokes: [strokeText])
        case .chord(let strokeTexts):
            shortcut = parseStoredShortcut(strokes: strokeTexts)
        }

        guard let shortcut else { return nil }
        if let normalized = action.normalizedRecordedShortcut(shortcut) {
            return normalized
        }
        return action.usesNumberedDigitMatching ? nil : shortcut
    }

    private func parseStoredShortcut(strokes: [String]) -> StoredShortcut? {
        guard !strokes.isEmpty, strokes.count <= 2 else { return nil }
        let parsedStrokes = strokes.compactMap(parseStroke(_:))
        guard parsedStrokes.count == strokes.count, let firstStroke = parsedStrokes.first else {
            return nil
        }
        let secondStroke = parsedStrokes.count == 2 ? parsedStrokes[1] : nil
        return StoredShortcut(first: firstStroke, second: secondStroke)
    }

    private func parseStroke(_ rawValue: String) -> ShortcutStroke? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let parts = trimmed.split(separator: "+", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard !parts.isEmpty, let lastPart = parts.last, !lastPart.isEmpty else {
            return nil
        }

        var command = false
        var shift = false
        var option = false
        var control = false

        for modifier in parts.dropLast() {
            switch modifier.lowercased() {
            case "cmd", "command", "⌘":
                command = true
            case "shift", "⇧":
                shift = true
            case "opt", "option", "alt", "⌥":
                option = true
            case "ctrl", "control", "ctl", "⌃":
                control = true
            default:
                return nil
            }
        }

        guard let key = parseKeyToken(lastPart) else { return nil }
        return ShortcutStroke(
            key: key,
            command: command,
            shift: shift,
            option: option,
            control: control
        )
    }

    private func parseKeyToken(_ rawValue: String) -> String? {
        let lowered = rawValue.lowercased()
        switch lowered {
        case "left", "arrowleft", "leftarrow", "←":
            return "←"
        case "right", "arrowright", "rightarrow", "→":
            return "→"
        case "up", "arrowup", "uparrow", "↑":
            return "↑"
        case "down", "arrowdown", "downarrow", "↓":
            return "↓"
        case "tab":
            return "\t"
        case "return", "enter", "↩":
            return "\r"
        case "space":
            return " "
        case "comma":
            return ","
        case "period", "dot":
            return "."
        case "slash":
            return "/"
        case "backslash":
            return "\\"
        case "semicolon":
            return ";"
        case "quote", "apostrophe":
            return "'"
        case "backtick", "grave":
            return "`"
        case "minus", "hyphen":
            return "-"
        case "plus", "equals":
            return "="
        case "leftbracket", "openbracket":
            return "["
        case "rightbracket", "closebracket":
            return "]"
        default:
            guard lowered.count == 1 else { return nil }
            return lowered
        }
    }
}

private struct KeyboardShortcutSettingsFile: Decodable {
    let shortcuts: [String: KeyboardShortcutBindingDefinition]?
}

private enum KeyboardShortcutBindingDefinition: Decodable {
    case single(String)
    case chord([String])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(String.self) {
            self = .single(value)
            return
        }
        if let values = try? container.decode([String].self) {
            self = .chord(values)
            return
        }
        throw DecodingError.typeMismatch(
            KeyboardShortcutBindingDefinition.self,
            DecodingError.Context(
                codingPath: decoder.codingPath,
                debugDescription: "Expected a shortcut string or a two-stroke shortcut array"
            )
        )
    }
}

private final class ShortcutSettingsFileWatcher {
    private let path: String
    private let fileManager: FileManager
    private let onChange: () -> Void
    private let watchQueue = DispatchQueue(label: "com.cmux.shortcut-settings-file-watch")

    private var source: DispatchSourceFileSystemObject?

    init(path: String, fileManager: FileManager = .default, onChange: @escaping () -> Void) {
        self.path = path
        self.fileManager = fileManager
        self.onChange = onChange
        start()
    }

    func stop() {
        source?.cancel()
        source = nil
    }

    private func start() {
        stop()

        if fileManager.fileExists(atPath: path) {
            startFileWatcher()
        } else {
            startDirectoryWatcher()
        }
    }

    private func startFileWatcher() {
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else {
            startDirectoryWatcher()
            return
        }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .delete, .rename, .extend],
            queue: watchQueue
        )

        source.setEventHandler { [weak self] in
            guard let self else { return }
            let flags = source.data
            if flags.contains(.delete) || flags.contains(.rename) {
                self.start()
            }
            self.onChange()
        }

        source.setCancelHandler {
            Darwin.close(fd)
        }

        source.resume()
        self.source = source
    }

    private func startDirectoryWatcher() {
        let directoryPath = (path as NSString).deletingLastPathComponent
        if !fileManager.fileExists(atPath: directoryPath) {
            try? fileManager.createDirectory(
                atPath: directoryPath,
                withIntermediateDirectories: true,
                attributes: nil
            )
        }

        let fd = open(directoryPath, O_EVTONLY)
        guard fd >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .link, .rename],
            queue: watchQueue
        )

        source.setEventHandler { [weak self] in
            guard let self else { return }
            guard self.fileManager.fileExists(atPath: self.path) else { return }
            self.start()
            self.onChange()
        }

        source.setCancelHandler {
            Darwin.close(fd)
        }

        source.resume()
        self.source = source
    }
}
