import AppKit
import Bonsplit
import CmuxWorkspaces

struct CmuxConfigUIDefinition: Codable, Sendable, Hashable {
    var newWorkspace: CmuxConfigButtonPlacement?
    var surfaceTabBar: CmuxSurfaceTabBarUIDefinition?
}

struct CmuxSurfaceTabBarUIDefinition: Codable, Sendable, Hashable {
    var buttons: [CmuxSurfaceTabBarButton]?
}

struct CmuxConfigButtonPlacement: Codable, Sendable, Hashable {
    var action: String?
    var icon: CmuxButtonIcon?
    var tooltip: String?
    var contextMenu: [CmuxConfigContextMenuItem]?

    private enum CodingKeys: String, CodingKey {
        case action
        case icon
        case tooltip
        case contextMenu
        case rightClick
    }

    init(
        action: String? = nil,
        icon: CmuxButtonIcon? = nil,
        tooltip: String? = nil,
        contextMenu: [CmuxConfigContextMenuItem]? = nil
    ) {
        self.action = action
        self.icon = icon
        self.tooltip = tooltip
        self.contextMenu = contextMenu
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        action = try Self.trimmedString(forKey: .action, in: container)
        icon = try container.decodeIfPresent(CmuxButtonIcon.self, forKey: .icon)
        tooltip = try Self.trimmedString(forKey: .tooltip, in: container, allowBlankAsNil: true)
        contextMenu = try container.decodeIfPresent([CmuxConfigContextMenuItem].self, forKey: .contextMenu)
            ?? container.decodeIfPresent([CmuxConfigContextMenuItem].self, forKey: .rightClick)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(action, forKey: .action)
        try container.encodeIfPresent(icon, forKey: .icon)
        try container.encodeIfPresent(tooltip, forKey: .tooltip)
        try container.encodeIfPresent(contextMenu, forKey: .contextMenu)
    }

    private static func trimmedString(
        forKey key: CodingKeys,
        in container: KeyedDecodingContainer<CodingKeys>,
        allowBlankAsNil: Bool = false
    ) throws -> String? {
        guard container.contains(key) else { return nil }
        let raw = try container.decode(String.self, forKey: key)
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            if allowBlankAsNil { return nil }
            throw DecodingError.dataCorruptedError(
                forKey: key,
                in: container,
                debugDescription: "\(key.stringValue) must not be blank"
            )
        }
        return trimmed
    }
}

// `CmuxConfigContextMenuActionItem` + `CmuxConfigContextMenuItem` (the
// `cmux.json` button-`contextMenu` wire-schema value types) now live in
// CmuxWorkspaces/CustomLayout/ alongside `CmuxButtonIcon`; the app reaches them
// through these module-wide typealiases (`import CmuxWorkspaces`, already
// imported above). The AppKit `CmuxButtonIcon.contextMenuImage(...)` renderer
// below stays app-side.
typealias CmuxConfigContextMenuActionItem = CmuxWorkspaces.CmuxConfigContextMenuActionItem
typealias CmuxConfigContextMenuItem = CmuxWorkspaces.CmuxConfigContextMenuItem

// TODO(refactor): `CmuxResolvedConfigMenuAction`/`CmuxResolvedConfigContextMenuItem`
// stay app-side (they reach app trust/exec via `CmuxResolvedConfigAction`). They
// do not reference the moved wire-schema types, so the typealiases above do not
// affect them.
struct CmuxResolvedConfigMenuAction: Identifiable, Sendable, Hashable {
    var id: String
    var title: String
    var icon: CmuxButtonIcon?
    var iconSourcePath: String?
    var tooltip: String?
    var action: CmuxResolvedConfigAction
}

enum CmuxResolvedConfigContextMenuItem: Identifiable, Sendable, Hashable {
    case action(CmuxResolvedConfigMenuAction)
    case separator(id: String)

    var id: String {
        switch self {
        case .action(let action):
            return action.id
        case .separator(let id):
            return id
        }
    }
}

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
