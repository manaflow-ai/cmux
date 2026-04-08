import AppKit

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

    deinit {
        if let iconChangeObserver {
            DistributedNotificationCenter.default().removeObserver(iconChangeObserver)
        }
    }

    func setDockTile(_ dockTile: NSDockTile?) {
        if let iconChangeObserver {
            DistributedNotificationCenter.default().removeObserver(iconChangeObserver)
            self.iconChangeObserver = nil
        }

        guard let dockTile else { return }
        updateDockTile(dockTile)

        iconChangeObserver = DistributedNotificationCenter.default().addObserver(
            forName: cmuxAppIconDidChangeNotification,
            object: nil,
            queue: nil
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

    private var appDefaults: UserDefaults? {
        guard let bundleIdentifier = appBundle?.bundleIdentifier else { return nil }
        return UserDefaults(suiteName: bundleIdentifier)
    }

    private func updateDockTile(_ dockTile: NSDockTile) {
        let mode = DockTileAppIconMode(defaultsValue: appDefaults?.string(forKey: cmuxAppIconModeKey))
        guard let imageName = mode.imageName,
              let icon = appBundle?.image(forResource: imageName) else {
            dockTile.showDefaultAppIcon()
            return
        }

        dockTile.showIcon(icon)
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
        DispatchQueue.main.async {
            self.contentView = nil
            self.display()
        }
    }

    func showIcon(_ newIcon: NSImage) {
        DispatchQueue.main.async {
            let iconView = NSImageView(frame: CGRect(origin: .zero, size: self.size))
            iconView.wantsLayer = true
            iconView.image = newIcon
            self.contentView = iconView
            self.display()
        }
    }
}

extension NSDockTile: @unchecked @retroactive Sendable {}
