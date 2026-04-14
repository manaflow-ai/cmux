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

private enum DockTileAppIconImageFactory {
    static func makeImage(
        for mode: DockTileAppIconMode,
        bundle: Bundle?
    ) -> NSImage? {
        switch mode {
        case .automatic:
            guard let light = bundle?.image(forResource: NSImage.Name("AppIconLight")),
                  let dark = bundle?.image(forResource: NSImage.Name("AppIconDark")) else {
                return nil
            }
            return appearanceAwareImage(light: light, dark: dark)
        case .light, .dark:
            guard let imageName = mode.imageName else { return nil }
            return bundle?.image(forResource: imageName)
        }
    }

    private static func appearanceAwareImage(
        light: NSImage,
        dark: NSImage,
        resolveIsDark: @escaping @Sendable () -> Bool = {
            MainActor.assumeIsolated {
                NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            }
        }
    ) -> NSImage? {
        let size = light.size.width > 0 && light.size.height > 0 ? light.size : dark.size
        guard size.width > 0, size.height > 0 else {
            return nil
        }

        return NSImage(size: size, flipped: false) { rect in
            let source = resolveIsDark() ? dark : light
            source.draw(
                in: rect,
                from: CGRect(origin: .zero, size: source.size),
                operation: .copy,
                fraction: 1.0
            )
            return true
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
        guard let icon = DockTileAppIconImageFactory.makeImage(for: mode, bundle: appBundle) else {
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
