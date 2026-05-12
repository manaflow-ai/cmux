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
}

@MainActor
private final class FileExplorerGitStatusColorPalette {
    static let shared = FileExplorerGitStatusColorPalette()

    private let defaults: UserDefaults
    private let notificationCenter: NotificationCenter
    private var colorsByStatus: [String: NSColor] = [:]
    private var styleObserver: NSObjectProtocol?

    init(
        defaults: UserDefaults = .standard,
        notificationCenter: NotificationCenter = .default
    ) {
        self.defaults = defaults
        self.notificationCenter = notificationCenter
        reload()
        styleObserver = notificationCenter.addObserver(
            forName: .fileExplorerStyleDidChange,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            if Thread.isMainThread {
                MainActor.assumeIsolated {
                    self?.reload()
                }
            } else {
                Task { @MainActor [weak self] in
                    self?.reload()
                }
            }
        }
    }

    deinit {
        if let styleObserver {
            notificationCenter.removeObserver(styleObserver)
        }
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

    private func reload() {
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
