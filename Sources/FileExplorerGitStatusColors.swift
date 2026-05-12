import AppKit
import Foundation

enum FileExplorerGitStatusColorSettings {
    static let userDefaultsKey = "fileExplorer.gitStatusColors"

    static func normalizedStatusName(_ rawName: String) -> String? {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard GitFileStatus(rawValue: name) != nil else { return nil }
        return name
    }

    @MainActor
    static func resolvedColor(
        for status: GitFileStatus,
        fallback: NSColor,
        defaults: UserDefaults = .standard
    ) -> NSColor {
        FileExplorerGitStatusColorPalette.shared.color(for: status, fallback: fallback, defaults: defaults)
    }

    // Settings file application mutates UserDefaults synchronously, then refreshes this
    // cache before row-reload observers consume the shared File Explorer repaint signal.
    // The palette intentionally does not observe that broad UI notification itself.
    static func reloadSharedPaletteOnMainThread() {
        precondition(Thread.isMainThread, "File Explorer git status color palette reload must run on the main thread")
        MainActor.assumeIsolated {
            FileExplorerGitStatusColorPalette.shared.reload()
        }
    }
}

@MainActor
private final class FileExplorerGitStatusColorPalette {
    static let shared = FileExplorerGitStatusColorPalette()

    private let defaults: UserDefaults
    private var colorsByStatus: [String: NSColor] = [:]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        reload()
    }

    func color(
        for status: GitFileStatus,
        fallback: NSColor,
        defaults requestedDefaults: UserDefaults
    ) -> NSColor {
        guard requestedDefaults === defaults else {
            return Self.loadedColors(from: requestedDefaults)[status.rawValue] ?? fallback
        }
        let color = colorsByStatus[status.rawValue]
        return color ?? fallback
    }

    func reload() {
        let colors = Self.loadedColors(from: defaults)
        colorsByStatus = colors
    }

    private static func loadedColors(from defaults: UserDefaults) -> [String: NSColor] {
        guard let colors = defaults.dictionary(
            forKey: FileExplorerGitStatusColorSettings.userDefaultsKey
        ) else {
            return [:]
        }
        return colors.reduce(into: [:]) { result, pair in
            guard let hex = pair.value as? String,
                  let status = FileExplorerGitStatusColorSettings.normalizedStatusName(pair.key),
                  let color = NSColor(hex: hex) else {
                return
            }
            result[status] = color
        }
    }
}
