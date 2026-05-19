import AppKit
import CoreServices

private let cmuxAppIconDidChangeNotification = Notification.Name("com.cmuxterm.appIconDidChange")
private let cmuxAppIconModeKey = "appIconMode"
private let cmuxNotificationDockBadgeLabelKey = "notificationDockBadgeLabel"

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
        // The default untagged Debug app is rebuilt and re-signed in place during CI.
        // Persisting a custom icon there leaves Finder metadata behind and breaks codesign.
        return appBundleURL.lastPathComponent != "cmux DEV.app"
    }

    private var appDefaults: UserDefaults? {
        guard let bundleIdentifier = appBundle?.bundleIdentifier else { return nil }
        return UserDefaults(suiteName: bundleIdentifier)
    }

    private func updateDockTile(_ dockTile: NSDockTile) {
        Self.assertMainQueue()

        let mode = DockTileAppIconMode(defaultsValue: appDefaults?.string(forKey: cmuxAppIconModeKey))
        let badgeLabel = DockTileBadgeRenderer.normalizedBadgeLabel(
            appDefaults?.string(forKey: cmuxNotificationDockBadgeLabelKey)
        )
        let isDarkAppearance = NSApp?.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        guard let appBundleURL else {
            dockTile.showDefaultAppIcon(badgeLabel: badgeLabel)
            return
        }

        guard let imageName = mode.imageName(isDarkAppearance: isDarkAppearance),
              let icon = appBundle?.image(forResource: imageName) else {
            if shouldPersistBundleIcon {
                NSWorkspace.shared.setIcon(nil, forFile: appBundleURL.path, options: [])
                NSWorkspace.shared.noteFileSystemChanged(appBundleURL.path)
                _ = LSRegisterURL(appBundleURL as CFURL, true)
            }
            dockTile.showDefaultAppIcon(badgeLabel: badgeLabel)
            return
        }

        if shouldPersistBundleIcon {
            NSWorkspace.shared.setIcon(icon, forFile: appBundleURL.path, options: [])
            NSWorkspace.shared.noteFileSystemChanged(appBundleURL.path)
            _ = LSRegisterURL(appBundleURL as CFURL, true)
        }
        dockTile.showIcon(icon, badgeLabel: badgeLabel)
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

private enum DockTileBadgeRenderer {
    static func normalizedBadgeLabel(_ rawLabel: String?) -> String? {
        guard let label = rawLabel?.trimmingCharacters(in: .whitespacesAndNewlines), !label.isEmpty else {
            return nil
        }
        return label
    }

    static func image(baseIcon: NSImage, badgeLabel rawBadgeLabel: String?) -> NSImage {
        guard let badgeLabel = normalizedBadgeLabel(rawBadgeLabel) else {
            return baseIcon
        }

        let size = normalizedIconSize(baseIcon.size)
        let result = NSImage(size: size)
        result.isTemplate = false
        result.lockFocus()
        defer { result.unlockFocus() }

        baseIcon.draw(
            in: NSRect(origin: .zero, size: size),
            from: NSRect(origin: .zero, size: baseIcon.size),
            operation: .sourceOver,
            fraction: 1
        )
        drawBadge(badgeLabel, in: NSRect(origin: .zero, size: size))
        return result
    }

    private static func normalizedIconSize(_ size: NSSize) -> NSSize {
        guard size.width > 0, size.height > 0 else {
            return NSSize(width: 128, height: 128)
        }
        return size
    }

    private static func drawBadge(_ label: String, in bounds: NSRect) {
        guard bounds.width > 0, bounds.height > 0 else { return }

        NSGraphicsContext.current?.shouldAntialias = true

        let iconEdge = min(bounds.width, bounds.height)
        let badgeHeight = max(18, iconEdge * 0.34)
        let horizontalPadding = badgeHeight * 0.28
        let maxBadgeWidth = bounds.width * 0.86
        let font = badgeFont(
            fitting: label,
            badgeHeight: badgeHeight,
            horizontalPadding: horizontalPadding,
            maxBadgeWidth: maxBadgeWidth
        )
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.white,
        ]
        let textSize = label.size(withAttributes: attributes)
        let badgeWidth = min(maxBadgeWidth, max(badgeHeight, ceil(textSize.width + horizontalPadding * 2)))
        let badgeRect = NSRect(
            x: bounds.maxX - badgeWidth - iconEdge * 0.02,
            y: bounds.maxY - badgeHeight - iconEdge * 0.02,
            width: badgeWidth,
            height: badgeHeight
        )

        NSColor.white.setFill()
        NSBezierPath(
            roundedRect: badgeRect.insetBy(dx: -badgeHeight * 0.07, dy: -badgeHeight * 0.07),
            xRadius: badgeHeight * 0.58,
            yRadius: badgeHeight * 0.58
        ).fill()
        NSColor(calibratedRed: 1.0, green: 0.12, blue: 0.16, alpha: 1.0).setFill()
        NSBezierPath(roundedRect: badgeRect, xRadius: badgeHeight / 2, yRadius: badgeHeight / 2).fill()

        let textRect = NSRect(
            x: badgeRect.midX - textSize.width / 2,
            y: badgeRect.midY - textSize.height / 2,
            width: textSize.width,
            height: textSize.height
        )
        label.draw(in: textRect, withAttributes: attributes)
    }

    private static func badgeFont(
        fitting label: String,
        badgeHeight: CGFloat,
        horizontalPadding: CGFloat,
        maxBadgeWidth: CGFloat
    ) -> NSFont {
        let baseSize = max(11, badgeHeight * 0.56)
        let baseFont = NSFont.systemFont(ofSize: baseSize, weight: .bold)
        let textWidth = label.size(withAttributes: [.font: baseFont]).width
        let availableWidth = max(1, maxBadgeWidth - horizontalPadding * 2)
        guard textWidth > availableWidth else {
            return baseFont
        }
        return NSFont.systemFont(
            ofSize: max(8, floor(baseSize * availableWidth / max(textWidth, 1))),
            weight: .bold
        )
    }
}

private extension NSDockTile {
    func showDefaultAppIcon(badgeLabel: String?) {
        CmuxDockTilePlugin.assertMainQueue()

        contentView = nil
        self.badgeLabel = badgeLabel
        display()
    }

    func showIcon(_ newIcon: NSImage, badgeLabel: String?) {
        CmuxDockTilePlugin.assertMainQueue()

        let iconView = NSImageView(frame: CGRect(origin: .zero, size: size))
        iconView.wantsLayer = true
        iconView.image = DockTileBadgeRenderer.image(baseIcon: newIcon, badgeLabel: badgeLabel)
        contentView = iconView
        self.badgeLabel = nil
        display()
    }
}

extension NSDockTile: @unchecked @retroactive Sendable {}
