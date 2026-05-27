import AppKit
import Foundation

enum BrowserEngineKind: String, CaseIterable, Identifiable {
    case chromium
    case webKit

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .chromium:
            return String(localized: "browser.engine.chromium", defaultValue: "Chrome (CEF)")
        case .webKit:
            return String(localized: "browser.engine.webkit", defaultValue: "WebKit")
        }
    }
}

enum BrowserEngineSettings {
    static let engineKey = "browserEngine"
    static let chromeExtensionDirectoriesKey = "browserChromeExtensionDirectories"
    static let didChangeNotification = Notification.Name("cmux.browserEngineDidChange")

    static let defaultEngine: BrowserEngineKind = .chromium
    static let defaultChromeExtensionDirectories = ""

    static func engine(for rawValue: String?) -> BrowserEngineKind {
        guard let rawValue else { return defaultEngine }

        switch rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "chromium", "chrome", "cef":
            return .chromium
        case "webkit", "web-kit", "wkwebview", "wk":
            return .webKit
        default:
            return defaultEngine
        }
    }

    static func preferredEngine(defaults: UserDefaults = .standard) -> BrowserEngineKind {
        engine(for: defaults.string(forKey: engineKey))
    }

    static func effectiveEngine(
        chromiumHostAvailable: Bool = CMUXChromiumRuntime.shared().isBrowserHostAvailable,
        defaults: UserDefaults = .standard
    ) -> BrowserEngineKind {
        let preferred = preferredEngine(defaults: defaults)
        guard preferred == .chromium else { return .webKit }
        return chromiumHostAvailable ? .chromium : .webKit
    }

    static func chromeExtensionDirectoryPaths(defaults: UserDefaults = .standard) -> [String] {
        chromeExtensionDirectoryPaths(rawValue: defaults.string(forKey: chromeExtensionDirectoriesKey))
    }

    static func chromeExtensionDirectoryPaths(rawValue: String?) -> [String] {
        guard let rawValue else { return [] }
        return rawValue
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
    }

    static func setPreferredEngine(_ engine: BrowserEngineKind, defaults: UserDefaults = .standard) {
        defaults.set(engine.rawValue, forKey: engineKey)
        defaults.synchronize()
        NotificationCenter.default.post(name: didChangeNotification, object: nil)
    }

    static func runtimeStatusSubtitle(defaults: UserDefaults = .standard) -> String {
        let preferred = preferredEngine(defaults: defaults)
        guard preferred == .chromium else {
            return String(
                localized: "settings.browser.engine.subtitle.webkit",
                defaultValue: "Uses Apple WebKit for embedded browser tabs."
            )
        }

        let runtime = CMUXChromiumRuntime.shared()
        if runtime.isBrowserHostAvailable {
            return String(
                localized: "settings.browser.engine.subtitle.chromiumAvailable",
                defaultValue: "Uses Chromium Embedded Framework for browser tabs, DevTools, and unpacked Chrome extensions."
            )
        }

        return String(
            localized: "settings.browser.engine.subtitle.chromiumFallback",
            defaultValue: "Chrome is selected. This build uses WebKit until the CEF runtime is bundled and enabled."
        )
    }
}

