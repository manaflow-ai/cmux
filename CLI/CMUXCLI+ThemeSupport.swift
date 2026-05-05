import Foundation
import TerminalThemeCore

extension CMUXCLI {
    func availableThemeNames() -> [String] {
        TerminalThemeSettings.availableThemeNames(
            resolvedExecutableURL: resolvedExecutableURL()
        )
    }

    func validatedThemeName(_ rawValue: String, availableThemes: [String]) throws -> String {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw CLIError(message: "Theme name cannot be empty")
        }
        guard TerminalThemeSettings.isSupportedThemeName(trimmed) else {
            throw CLIError(message: "Theme names cannot contain ':' or ','")
        }
        if let matched = availableThemes.first(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            return matched
        }
        if availableThemes.isEmpty {
            return trimmed
        }
        throw CLIError(message: "Unknown theme '\(trimmed)'. Run 'cmux themes' to list available themes.")
    }

    func themeConfigSearchURLs() -> [URL] {
        TerminalThemeSettings.themeConfigSearchURLs(
            currentBundleIdentifier: currentCmuxAppBundleIdentifier()
        )
    }

    func lastThemeDirective(in contents: String) -> String? {
        TerminalThemeSettings.lastThemeDirective(in: contents)
    }

    func cmuxThemeOverrideConfigURL() throws -> URL {
        do {
            return try TerminalThemeSettings.managedConfigURL(bundleIdentifier: currentThemeManagedBundleIdentifier())
        } catch {
            throw CLIError(message: "Unable to resolve Application Support directory")
        }
    }

    func writeManagedThemeOverride(rawThemeValue: String) throws -> URL {
        try TerminalThemeSettings.writeManagedThemeOverride(
            rawThemeValue: rawThemeValue,
            bundleIdentifier: currentThemeManagedBundleIdentifier()
        )
    }

    func clearManagedThemeOverride() throws -> URL {
        try TerminalThemeSettings.clearManagedThemeOverride(
            bundleIdentifier: currentThemeManagedBundleIdentifier()
        )
    }

    func reloadThemesIfPossible() -> ThemeReloadStatus {
        let bundleIdentifier = currentThemeManagedBundleIdentifier()
        DistributedNotificationCenter.default().post(
            name: Notification.Name(Self.cmuxThemesReloadNotificationName),
            object: nil,
            userInfo: ["bundleIdentifier": bundleIdentifier]
        )
        return ThemeReloadStatus(requested: true, targetBundleIdentifier: bundleIdentifier)
    }

    private func currentThemeManagedBundleIdentifier() -> String {
        currentCmuxAppBundleIdentifier() ?? Self.cmuxThemeOverrideBundleIdentifier
    }

    func currentCmuxAppBundleIdentifier() -> String? {
        if let bundleIdentifier = ProcessInfo.processInfo.environment["CMUX_BUNDLE_ID"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !bundleIdentifier.isEmpty {
            return bundleIdentifier
        }

        if let bundleIdentifier = Bundle.main.bundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines),
           !bundleIdentifier.isEmpty {
            return bundleIdentifier
        }

        guard let executableURL = resolvedExecutableURL() else {
            return nil
        }

        var current = executableURL.deletingLastPathComponent().standardizedFileURL
        while true {
            if current.pathExtension == "app",
               let bundleIdentifier = Bundle(url: current)?.bundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines),
               !bundleIdentifier.isEmpty {
                return bundleIdentifier
            }

            if current.lastPathComponent == "Contents" {
                let appURL = current.deletingLastPathComponent().standardizedFileURL
                if appURL.pathExtension == "app",
                   let bundleIdentifier = Bundle(url: appURL)?.bundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !bundleIdentifier.isEmpty {
                    return bundleIdentifier
                }
            }

            guard let parent = parentSearchURL(for: current) else {
                break
            }
            current = parent
        }

        return nil
    }
}
