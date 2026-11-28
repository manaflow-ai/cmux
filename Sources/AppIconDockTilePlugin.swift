import AppKit
import CoreServices

private let cmuxAppIconDidChangeNotification = Notification.Name("com.cmuxterm.appIconDidChange")
private let cmuxAppIconModeKey = "appIconMode"

private enum DockTileAppIconMode: String {
    case automatic
    case light
    case dark

    init(defaultsValue: String?) {
        self = Self(rawValue: defaultsValue ?? "") ?? .automatic
    }

    var imageName: NSImage.Name? {
        switch self {
        case .automatic:
            return nil
        case .light:
            return NSImage.Name("AppIconLight")
        case .dark:
            return NSImage.Name("AppIconDark")
        }
    }
}

final class CmuxDockTilePlugin: NSObject, NSDockTilePlugIn {
    // The plugin can stay alive while the app remains in the Dock, even after quit.
    // Keep the state minimal and derive everything from the enclosing app bundle.
    private let pluginBundle = Bundle(for: CmuxDockTilePlugin.self)
    private var iconChangeObserver: NSObjectProtocol?
    private var hasClearedAutomaticOverride = false

    deinit {
        if let iconChangeObserver {
            DistributedNotificationCenter.default().removeObserver(iconChangeObserver)
        }
    }

    func setDockTile(_ dockTile: NSDockTile?) {
        Self.performOnMain { [self] in
            setDockTileOnMain(dockTile)
        }
    }

    private func setDockTileOnMain(_ dockTile: NSDockTile?) {
        Self.assertMainQueue()

        if let iconChangeObserver {
            DistributedNotificationCenter.default().removeObserver(iconChangeObserver)
            self.iconChangeObserver = nil
        }
        hasClearedAutomaticOverride = false

        guard let dockTile else { return }
        updateDockTile(dockTile)

        iconChangeObserver = DistributedNotificationCenter.default().addObserver(
            forName: cmuxAppIconDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.updateDockTile(dockTile)
        }
    }

    private var appBundleURL: URL? {
        Self.appBundleURL(for: pluginBundle.bundleURL)
    }

    private var appBundle: Bundle? {
        guard let appBundleURL else { return nil }
        return Bundle(url: appBundleURL)
    }

    private var shouldPersistBundleIcon: Bool {
        guard let appBundleURL else { return false }
        return AppBundleIconPersistencePolicy.shouldPersist(
            bundleIdentifier: appBundle?.bundleIdentifier,
            appBundleLastPathComponent: appBundleURL.lastPathComponent,
            persistenceDisabled: appDefaults?.bool(
                forKey: AppBundleIconPersistencePolicy.disablePersistenceDefaultsKey
            ) ?? false
        )
    }

    private var appDefaults: UserDefaults? {
        guard let bundleIdentifier = appBundle?.bundleIdentifier else { return nil }
        return UserDefaults(suiteName: bundleIdentifier)
    }

    private func updateDockTile(_ dockTile: NSDockTile) {
        Self.assertMainQueue()

        let mode = DockTileAppIconMode(defaultsValue: appDefaults?.string(forKey: cmuxAppIconModeKey))
        guard let appBundleURL else {
            dockTile.showDefaultAppIcon()
            return
        }

        // For automatic mode, defer to the bundle's AppIcon asset catalog,
        // which carries `luminosity: dark` appearance variants for every size.
        // The Dock plugin runs in the Dock process where NSApp.effectiveAppearance
        // is not a reliable signal for the user's system dark/light setting, so
        // picking AppIconDark/AppIconLight here and persisting it via
        // NSWorkspace.setIcon would lock the bundle icon to whatever variant the
        // Dock happened to detect at quit time (issue #3303). Clearing any
        // previous custom override lets macOS reassert the asset catalog's
        // adaptive icon and switch automatically with system appearance.
        // The clear is gated on `hasClearedAutomaticOverride` so the redundant
        // workspace ops don't repeat while the plugin remains in automatic mode.
        if mode == .automatic {
            if !hasClearedAutomaticOverride {
                persistBundleIcon(nil, at: appBundleURL)
                hasClearedAutomaticOverride = true
            }
            dockTile.showDefaultAppIcon()
            return
        }

        // Manual mode is about to write a custom bundle icon, so any previously
        // recorded "automatic override cleared" state no longer applies.
        hasClearedAutomaticOverride = false

        guard let imageName = mode.imageName,
              let icon = appBundle?.image(forResource: imageName) else {
            persistBundleIcon(nil, at: appBundleURL)
            dockTile.showDefaultAppIcon()
            return
        }

        persistBundleIcon(icon, at: appBundleURL)
        dockTile.showIcon(icon)
    }

    private func persistBundleIcon(_ icon: NSImage?, at appBundleURL: URL) {
        guard shouldPersistBundleIcon else { return }
        NSWorkspace.shared.setIcon(icon, forFile: appBundleURL.path, options: [])
        NSWorkspace.shared.noteFileSystemChanged(appBundleURL.path)
        _ = LSRegisterURL(appBundleURL as CFURL, true)
    }

    private static func performOnMain(_ work: @escaping () -> Void) {
        if Thread.isMainThread {
            work()
        } else {
            DispatchQueue.main.async(execute: work)
        }
    }

    fileprivate static func assertMainQueue() {
        #if DEBUG
        dispatchPrecondition(condition: .onQueue(.main))
        #endif
    }

    /// Determine the enclosing app bundle for the dock tile plugin bundle.
    static func appBundleURL(for pluginBundleURL: URL) -> URL? {
        var url = pluginBundleURL
        while true {
            if url.pathExtension.compare("app", options: .caseInsensitive) == .orderedSame {
                return url
            }

            let parent = url.deletingLastPathComponent()
            if parent.path == url.path {
                return nil
            }

            url = parent
        }
    }
}

private extension NSDockTile {
    func showDefaultAppIcon() {
        CmuxDockTilePlugin.assertMainQueue()

        contentView = nil
        display()
    }

    func showIcon(_ newIcon: NSImage) {
        CmuxDockTilePlugin.assertMainQueue()

        let iconView = NSImageView(frame: CGRect(origin: .zero, size: size))
        iconView.wantsLayer = true
        iconView.image = newIcon
        contentView = iconView
        display()
    }
}

extension NSDockTile: @unchecked @retroactive Sendable {}
