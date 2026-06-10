import AppKit
import CmuxSidebarInterpreterClient
import CmuxSidebarRemoteRender
import CmuxSocketControl
import CmuxSettings
import CmuxSettingsUI
import CmuxUpdaterUI
import SwiftUI
import Observation
import Darwin
import Bonsplit
import UniformTypeIdentifiers


// MARK: - Cmd-Click File Route Settings
enum CmdClickMarkdownRouteSettings {
    static let key = "openMarkdownInCmuxViewer"
    static let didChangeNotification = Notification.Name("cmux.cmdClickMarkdownRouteDidChange")
    static let defaultValue = true

    static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: key) == nil ? defaultValue : defaults.bool(forKey: key)
    }

    static func setEnabled(
        _ enabled: Bool,
        defaults: UserDefaults = .standard,
        notificationCenter: NotificationCenter = .default
    ) {
        defaults.set(enabled, forKey: key)
        notifyDidChange(notificationCenter: notificationCenter)
    }

    static func notifyDidChange(notificationCenter: NotificationCenter = .default) {
        notificationCenter.post(name: didChangeNotification, object: nil)
    }

    /// Cheap extension check. Safe to call off the main thread before any
    /// filesystem probe so remote/non-markdown paths can be filtered early.
    static func isMarkdownPath(_ path: String) -> Bool {
        let ext = (path as NSString).pathExtension.lowercased()
        return ext == "md" || ext == "markdown" || ext == "mkd" || ext == "mdx"
    }

    static func shouldRoute(path: String, defaults: UserDefaults = .standard) -> Bool {
        guard isEnabled(defaults: defaults),
              isMarkdownPath(path) else { return false }
        // Match the `markdown.open` socket path: only route real, readable
        // files. Rejects FIFOs, device nodes, sockets, symlinks to non-regular
        // targets, and permission-denied paths so the viewer never opens into
        // an unavailable state.
        return CmdClickSupportedFileRouteSettings.isReadableRegularFile(path: path)
    }
}

enum CmdClickSupportedFileRouteSettings {
    static let key = "openSupportedFilesInCmux"
    static let didChangeNotification = Notification.Name("cmux.cmdClickSupportedFileRouteDidChange")
    static let defaultValue = true

    static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
        return defaults.object(forKey: key) == nil ? defaultValue : defaults.bool(forKey: key)
    }

    static func setEnabled(
        _ enabled: Bool,
        defaults: UserDefaults = .standard,
        notificationCenter: NotificationCenter = .default
    ) {
        defaults.set(enabled, forKey: key)
        notifyDidChange(notificationCenter: notificationCenter)
    }

    static func notifyDidChange(notificationCenter: NotificationCenter = .default) {
        notificationCenter.post(name: didChangeNotification, object: nil)
    }

    static func shouldRoute(path: String, defaults: UserDefaults = .standard) -> Bool {
        guard isEnabled(defaults: defaults) else { return false }
        return isReadableRegularFile(path: path)
    }

    static func isReadableRegularFile(path: String) -> Bool {
        let resolved = (path as NSString).resolvingSymlinksInPath
        guard FileManager.default.isReadableFile(atPath: resolved),
              let attrs = try? FileManager.default.attributesOfItem(atPath: resolved),
              (attrs[.type] as? FileAttributeType) == .typeRegular else {
            return false
        }
        return true
    }
}

