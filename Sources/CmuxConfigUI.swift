import AppKit
import Bonsplit
import CmuxWorkspaces

// `CmuxConfigUIDefinition` + `CmuxSurfaceTabBarUIDefinition` +
// `CmuxConfigButtonPlacement` (the `cmux.json` top-level `ui`-block wire-schema
// value types, including the custom `CmuxConfigButtonPlacement` decoder with the
// `rightClick` alias + blank-trimming) now live in CmuxWorkspaces/CustomLayout/
// alongside the field types they reference (`CmuxSurfaceTabBarButton`,
// `CmuxButtonIcon`, `CmuxConfigContextMenuItem`); the app reaches them through
// these module-wide typealiases (`import CmuxWorkspaces`, already imported
// above) so `CmuxConfigFile.ui` + `loadAll()` reads stay byte-identical. The
// AppKit `CmuxButtonIcon.contextMenuImage(...)` renderer below stays app-side.
typealias CmuxConfigUIDefinition = CmuxWorkspaces.CmuxConfigUIDefinition
typealias CmuxSurfaceTabBarUIDefinition = CmuxWorkspaces.CmuxSurfaceTabBarUIDefinition
typealias CmuxConfigButtonPlacement = CmuxWorkspaces.CmuxConfigButtonPlacement

// `CmuxConfigContextMenuActionItem` + `CmuxConfigContextMenuItem` (the
// `cmux.json` button-`contextMenu` wire-schema value types) now live in
// CmuxWorkspaces/CustomLayout/ alongside `CmuxButtonIcon`; the app reaches them
// through these module-wide typealiases (`import CmuxWorkspaces`, already
// imported above). The AppKit `CmuxButtonIcon.contextMenuImage(...)` renderer
// below stays app-side.
typealias CmuxConfigContextMenuActionItem = CmuxWorkspaces.CmuxConfigContextMenuActionItem
typealias CmuxConfigContextMenuItem = CmuxWorkspaces.CmuxConfigContextMenuItem

// `CmuxResolvedConfigMenuAction` + `CmuxResolvedConfigContextMenuItem` (the
// fully-resolved button context-menu value types) now live in
// CmuxWorkspaces/CustomLayout/ alongside `CmuxResolvedConfigAction`/`CmuxButtonIcon`,
// which they hold; the app reaches them through these module-wide typealiases
// (`import CmuxWorkspaces`, already imported above). The AppKit
// `CmuxButtonIcon.contextMenuImage(...)` renderer below stays app-side.
typealias CmuxResolvedConfigMenuAction = CmuxWorkspaces.CmuxResolvedConfigMenuAction
typealias CmuxResolvedConfigContextMenuItem = CmuxWorkspaces.CmuxResolvedConfigContextMenuItem

// `CmuxRestartBehavior` now lives in CmuxWorkspaces/CustomLayout/ alongside
// `CmuxCommandDefinition`; the app reaches it through the module-wide
// `typealias CmuxRestartBehavior = CmuxWorkspaces.CmuxRestartBehavior` declared
// in CmuxConfig.swift (`import CmuxWorkspaces`, already imported above).

extension CmuxButtonIcon {
    func contextMenuImage(configSourcePath: String?, globalConfigPath: String) -> NSImage? {
        switch bonsplitIcon(configSourcePath: configSourcePath, globalConfigPath: globalConfigPath) {
        case .systemImage(let symbolName):
            return NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
        case .emoji(let value, let scale):
            return Self.contextMenuEmojiImage(value, scale: scale)
        case .imageData(let data):
            guard let image = NSImage(data: data) else { return nil }
            return Self.normalizedContextMenuImage(image)
        }
    }

    private static let contextMenuIconMaximumDimension: CGFloat = 16

    private static func contextMenuEmojiImage(_ value: String, scale: Double) -> NSImage? {
        let clampedScale = min(max(scale, 0.25), 4)
        let font = NSFont.systemFont(ofSize: CGFloat(16.0 * clampedScale))
        let attributedString = NSAttributedString(string: value, attributes: [.font: font])
        let measuredSize = attributedString.size()
        let imageSize = NSSize(
            width: ceil(max(1, measuredSize.width)),
            height: ceil(max(1, measuredSize.height))
        )
        let image = NSImage(size: imageSize)
        image.lockFocus()
        attributedString.draw(at: .zero)
        image.unlockFocus()
        image.isTemplate = false
        return image
    }

    private static func normalizedContextMenuImage(_ source: NSImage) -> NSImage {
        let targetSize = contextMenuIconSize(for: source.size)
        let image = NSImage(size: targetSize)
        image.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        source.draw(in: NSRect(origin: .zero, size: targetSize))
        image.unlockFocus()
        image.isTemplate = false
        return image
    }

    static func contextMenuIconSize(for sourceSize: NSSize) -> NSSize {
        let maximumDimension = contextMenuIconMaximumDimension
        guard sourceSize.width.isFinite,
              sourceSize.height.isFinite,
              sourceSize.width > 0,
              sourceSize.height > 0 else {
            return NSSize(width: maximumDimension, height: maximumDimension)
        }
        let scale = maximumDimension / max(sourceSize.width, sourceSize.height)
        return NSSize(
            width: ceil(sourceSize.width * scale),
            height: ceil(sourceSize.height * scale)
        )
    }
}
