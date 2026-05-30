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

    func imageName(isDarkAppearance: Bool) -> NSImage.Name? {
        switch self {
        case .automatic:
            return isDarkAppearance ? NSImage.Name("AppIconDark") : NSImage.Name("AppIconLight")
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
    private var appearanceObservation: NSKeyValueObservation?

    deinit {
        if let iconChangeObserver {
            DistributedNotificationCenter.default().removeObserver(iconChangeObserver)
        }
        appearanceObservation?.invalidate()
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
        appearanceObservation?.invalidate()
        appearanceObservation = nil

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

        if let app = NSApp {
            appearanceObservation = app.observe(\.effectiveAppearance, options: []) { [weak self] _, _ in
                DispatchQueue.main.async {
                    guard let self, self.appearanceObservation != nil else { return }
                    self.updateDockTile(dockTile)
                }
            }
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
        let isDarkAppearance = NSApp?.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        guard let appBundleURL else {
            dockTile.showDefaultAppIcon()
            return
        }

        guard let imageName = mode.imageName(isDarkAppearance: isDarkAppearance),
              let icon = appBundle?.image(forResource: imageName) else {
            if shouldPersistBundleIcon {
                NSWorkspace.shared.setIcon(nil, forFile: appBundleURL.path, options: [])
                NSWorkspace.shared.noteFileSystemChanged(appBundleURL.path)
                _ = LSRegisterURL(appBundleURL as CFURL, true)
            }
            dockTile.showDefaultAppIcon()
            return
        }

        if shouldPersistBundleIcon {
            NSWorkspace.shared.setIcon(icon, forFile: appBundleURL.path, options: [])
            NSWorkspace.shared.noteFileSystemChanged(appBundleURL.path)
            _ = LSRegisterURL(appBundleURL as CFURL, true)
        }
        dockTile.showIcon(icon)
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
