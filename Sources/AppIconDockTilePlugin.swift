import AppKit

private let cmuxAppIconDidChangeNotification = Notification.Name("com.cmuxterm.appIconDidChange")
private let cmuxAppIconModeKey = "appIconMode"
private let cmuxAppearanceModeKey = "appearanceMode"
private let cmuxAppearanceAwareBundleIconNames: Set<String> = [
    "AppIcon",
    "AppIcon-Debug",
]

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

private enum DockTileAppearanceMode: String {
    case system
    case light
    case dark
    case auto

    init(defaultsValue: String?) {
        self = Self(rawValue: defaultsValue ?? "") ?? .system
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
        if mode == .automatic {
            let appearanceMode = DockTileAppearanceMode(defaultsValue: appDefaults?.string(forKey: cmuxAppearanceModeKey))
            if automaticModeUsesBundleIcon() && appearanceMode == .system {
                dockTile.showDefaultAppIcon()
                return
            }

            guard let icon = automaticIcon(appearanceMode: appearanceMode) else {
                dockTile.showDefaultAppIcon()
                return
            }

            dockTile.showIcon(icon)
            return
        }

        guard let imageName = mode.imageName,
              let icon = appBundle?.image(forResource: imageName) else {
            dockTile.showDefaultAppIcon()
            return
        }

        dockTile.showIcon(icon)
    }

    private func automaticModeUsesBundleIcon() -> Bool {
        guard let appBundle,
              let iconName = appBundle.object(forInfoDictionaryKey: "CFBundleIconName") as? String ??
                appBundle.object(forInfoDictionaryKey: "CFBundleIconFile") as? String else {
            return false
        }
        let normalizedIconName = (iconName as NSString).deletingPathExtension
        return cmuxAppearanceAwareBundleIconNames.contains(normalizedIconName)
    }

    private func automaticIcon(appearanceMode: DockTileAppearanceMode) -> NSImage? {
        guard let appBundle,
              let light = appBundle.image(forResource: NSImage.Name("AppIconLight")),
              let dark = appBundle.image(forResource: NSImage.Name("AppIconDark")) else {
            return nil
        }

        return appearanceAwareImage(light: light, dark: dark) {
            switch appearanceMode {
            case .light:
                return NSAppearance(named: .aqua) ?? NSAppearance.currentDrawing()
            case .dark:
                return NSAppearance(named: .darkAqua) ?? NSAppearance.currentDrawing()
            case .system, .auto:
                return NSAppearance.currentDrawing()
            }
        }
    }

    private func appearanceAwareImage(
        light: NSImage,
        dark: NSImage,
        appearance: @escaping () -> NSAppearance
    ) -> NSImage? {
        let lightIsRenderable = light.size.width > 0 && light.size.height > 0
        let darkIsRenderable = dark.size.width > 0 && dark.size.height > 0
        guard lightIsRenderable || darkIsRenderable else { return nil }

        let size = lightIsRenderable ? light.size : dark.size
        let image = NSImage(size: size, flipped: false) { rect in
            let isDark = appearance().bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let preferred = isDark ? dark : light
            let fallback = isDark ? light : dark
            let source = preferred.size.width > 0 && preferred.size.height > 0 ? preferred : fallback
            source.draw(in: rect)
            return true
        }
        image.cacheMode = .never
        return image
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
