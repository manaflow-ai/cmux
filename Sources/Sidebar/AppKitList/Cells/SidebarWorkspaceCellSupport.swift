import AppKit
import CmuxFoundation
import CmuxSettings
import CmuxSidebar
import CmuxWorkspaces
import Foundation

/// Resolved per-configure presentation values shared by every subview of the
/// AppKit workspace cell. Mirrors the color/font helpers `TabItemView`
/// computed in its body, resolved once against the cell's effective
/// appearance instead of the SwiftUI environment.
@MainActor
struct SidebarWorkspaceCellStyle {
    let snapshot: SidebarWorkspaceRowSnapshot
    let environment: SidebarWorkspaceListEnvironment
    let isDarkAppearance: Bool

    var settings: SidebarTabItemSettingsSnapshot { snapshot.settings }
    var workspace: SidebarWorkspaceSnapshotBuilder.Snapshot { snapshot.workspace }
    var fontScale: CGFloat { settings.sidebarFontScale }
    var isActive: Bool { snapshot.isActive }

    /// Magnified point size for a base size, matching `magnifiedFont(scaledFontSize(_:))`.
    func fontSize(_ base: CGFloat) -> CGFloat {
        environment.fontSize(base: base, sidebarFontScale: fontScale)
    }

    /// Scaled-only size (no global magnification), for the few metrics
    /// TabItemView derived from `fontScale` alone (badge/spinner/close sizes).
    func scaledSize(_ base: CGFloat) -> CGFloat {
        base * fontScale
    }

    var selectedBackground: NSColor {
        sidebarSelectedWorkspaceBackgroundNSColor(
            for: isDarkAppearance ? .dark : .light,
            sidebarSelectionColorHex: settings.selectionColorHex
        )
    }

    func selectedForeground(_ opacity: CGFloat) -> NSColor {
        sidebarSelectedWorkspaceForegroundNSColor(on: selectedBackground, opacity: opacity)
    }

    var primaryText: NSColor {
        isActive ? selectedForeground(1.0) : .labelColor
    }

    /// `activeSecondaryColor(_:)` from TabItemView: the opacity only applies
    /// to the inverted (selected-row) foreground; unselected rows use the
    /// plain secondary label color.
    func secondary(_ opacity: CGFloat = 0.75) -> NSColor {
        isActive ? selectedForeground(opacity) : .secondaryLabelColor
    }

    var accent: NSColor {
        cmuxAccentNSColor(for: isDarkAppearance ? .dark : .light)
    }

    var unreadBadgeFill: NSColor {
        if let hex = settings.notificationBadgeColorHex, let color = NSColor(hex: hex) {
            return color
        }
        return isActive ? primaryText.withAlphaComponent(0.25) : accent
    }

    var unreadBadgeText: NSColor {
        isActive ? primaryText : .white
    }

    var spinnerColor: NSColor {
        isActive ? selectedForeground(0.55) : .secondaryLabelColor
    }

    var progressTrack: NSColor {
        isActive
            ? secondary(0.15)
            : SidebarWorkspaceCellStyle.dimmed(.secondaryLabelColor, 0.2)
    }

    var progressFill: NSColor {
        isActive ? secondary(0.8) : accent
    }

    var pullRequestForeground: NSColor {
        isActive ? secondary(0.75) : .secondaryLabelColor
    }

    var descriptionForeground: NSColor {
        isActive ? secondary(0.84) : SidebarWorkspaceCellStyle.dimmed(.secondaryLabelColor, 0.95)
    }

    var rowBackgroundStyle: SidebarWorkspaceRowBackgroundStyle {
        sidebarWorkspaceRowBackgroundStyle(
            activeTabIndicatorStyle: settings.activeTabIndicatorStyle,
            isActive: isActive,
            isMultiSelected: snapshot.isMultiSelected,
            customColorHex: workspace.customColorHex,
            colorScheme: isDarkAppearance ? .dark : .light,
            sidebarSelectionColorHex: settings.selectionColorHex
        )
    }

    var railColor: NSColor? {
        sidebarWorkspaceRowExplicitRailNSColor(
            activeTabIndicatorStyle: settings.activeTabIndicatorStyle,
            customColorHex: workspace.customColorHex,
            colorScheme: isDarkAppearance ? .dark : .light
        )?.withAlphaComponent(0.95)
    }

    var activeBorderColor: NSColor? {
        guard isActive, settings.activeTabIndicatorStyle == .solidFill else { return nil }
        return NSColor.labelColor.withAlphaComponent(0.5)
    }

    func logLevelColor(_ level: SidebarLogLevel) -> NSColor {
        if isActive {
            switch level {
            case .info: return secondary(0.5)
            case .progress: return secondary(0.8)
            case .success, .warning, .error: return secondary(0.9)
            }
        }
        switch level {
        case .info: return .secondaryLabelColor
        case .progress: return .systemBlue
        case .success: return .systemGreen
        case .warning: return .systemOrange
        case .error: return .systemRed
        }
    }

    static func logLevelIcon(_ level: SidebarLogLevel) -> String {
        switch level {
        case .info: return "circle.fill"
        case .progress: return "arrowtriangle.right.fill"
        case .success: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .error: return "xmark.circle.fill"
        }
    }

    /// Multiplies a color's alpha (SwiftUI `.opacity(_:)` semantics — relative,
    /// not absolute like `withAlphaComponent`).
    static func dimmed(_ color: NSColor, _ factor: CGFloat) -> NSColor {
        color.withAlphaComponent(color.alphaComponent * factor)
    }
}

/// The per-configure inputs the cell fans out to its subviews.
@MainActor
struct SidebarWorkspaceCellContext {
    let style: SidebarWorkspaceCellStyle
    let isPointerHovering: Bool
    let isContextMenuOpen: Bool
    let isEditing: Bool
    let actions: SidebarWorkspaceRowActions?
    let host: SidebarWorkspaceCellHost?

    var snapshot: SidebarWorkspaceRowSnapshot { style.snapshot }
    var settings: SidebarTabItemSettingsSnapshot { style.settings }
    var workspace: SidebarWorkspaceSnapshotBuilder.Snapshot { style.workspace }

    var showsShortcutHints: Bool {
        snapshot.showsModifierShortcutHints || settings.alwaysShowShortcutHints
    }

    var showsCloseButton: Bool {
        isPointerHovering
            && !isContextMenuOpen
            && snapshot.canCloseWorkspace
            && !showsShortcutHints
    }
}

@MainActor
enum SidebarWorkspaceCellFonts {
    static func system(_ size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        .systemFont(ofSize: size, weight: weight)
    }

    static func monospaced(_ size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        .monospacedSystemFont(ofSize: size, weight: weight)
    }

    static func monospacedDigit(_ size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        .monospacedDigitSystemFont(ofSize: size, weight: weight)
    }

    static func rounded(_ size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        let base = NSFont.systemFont(ofSize: size, weight: weight)
        guard let descriptor = base.fontDescriptor.withDesign(.rounded),
              let font = NSFont(descriptor: descriptor, size: size) else {
            return base
        }
        return font
    }
}

@MainActor
enum SidebarWorkspaceCellSymbols {
    /// A template symbol image configured at `pointSize`, mirroring
    /// `CmuxSystemSymbolImage` (the caller passes the already-magnified size).
    static func image(
        _ systemName: String,
        pointSize: CGFloat,
        weight: NSFont.Weight = .regular
    ) -> NSImage? {
        guard let base = NSImage(systemSymbolName: systemName, accessibilityDescription: nil) else {
            return nil
        }
        let configuration = NSImage.SymbolConfiguration(
            pointSize: max(1, pointSize),
            weight: weight
        )
        let configured = base.withSymbolConfiguration(configuration) ?? base
        let image = (configured.copy() as? NSImage) ?? configured
        image.isTemplate = true
        return image
    }
}

extension String {
    /// Same bounding as ContentView's private `sidebarBoundedDisplayString`:
    /// truncates to line/character caps with a trailing ellipsis marker.
    func sidebarCellBoundedDisplayString(maxDisplayedLines: Int, maxDisplayedCharacters: Int) -> String {
        var result = ""
        result.reserveCapacity(maxDisplayedCharacters)
        var lineCount = 1
        var characterCount = 0
        var truncated = false

        for character in self {
            if characterCount >= maxDisplayedCharacters {
                truncated = true
                break
            }
            if character == "\n" {
                if lineCount >= maxDisplayedLines {
                    truncated = true
                    break
                }
                lineCount += 1
            }
            result.append(character)
            characterCount += 1
        }

        guard truncated else { return self }
        let trimmed = result.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "..." : trimmed + "..."
    }
}

@MainActor
enum SidebarWorkspaceCellMarkdown {
    /// Converts a parsed markdown `AttributedString` to an AppKit attributed
    /// string, resolving inline presentation intents (bold, italic, code,
    /// strikethrough) and links against the row's base font and color.
    /// Block-intent boundaries become single newlines; list markers are not
    /// reproduced.
    static func nsAttributed(
        from attributed: AttributedString,
        baseFont: NSFont,
        color: NSColor
    ) -> NSAttributedString {
        let result = NSMutableAttributedString()
        var previousBlockIdentity: Int?
        for run in attributed.runs {
            if let block = run.presentationIntent {
                let identity = block.components.first?.identity
                if let identity, let previous = previousBlockIdentity, identity != previous {
                    result.append(NSAttributedString(
                        string: "\n",
                        attributes: [.font: baseFont, .foregroundColor: color]
                    ))
                }
                previousBlockIdentity = identity
            }

            var font = baseFont
            var attributes: [NSAttributedString.Key: Any] = [.foregroundColor: color]
            if let intent = run.inlinePresentationIntent {
                if intent.contains(.code) {
                    font = NSFont.monospacedSystemFont(ofSize: baseFont.pointSize, weight: .regular)
                }
                var traits: NSFontDescriptor.SymbolicTraits = []
                if intent.contains(.stronglyEmphasized) { traits.insert(.bold) }
                if intent.contains(.emphasized) { traits.insert(.italic) }
                if !traits.isEmpty {
                    let descriptor = font.fontDescriptor.withSymbolicTraits(traits)
                    font = NSFont(descriptor: descriptor, size: baseFont.pointSize) ?? font
                }
                if intent.contains(.strikethrough) {
                    attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
                }
            }
            attributes[.font] = font
            if let link = run.link {
                attributes[.link] = link
                attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
            }
            result.append(NSAttributedString(
                string: String(attributed.characters[run.range]),
                attributes: attributes
            ))
        }
        return result
    }
}

/// Cell-local UI state that changes row height (metadata show-more, checklist
/// inline add/edit), keyed by workspace so the height-measuring sizing cell
/// sees the same state as the visible cell. Mirrors the `@State` the SwiftUI
/// rows kept. Observers let each window's table owner re-measure the row.
@MainActor
final class SidebarWorkspaceCellTransientState {
    static let shared = SidebarWorkspaceCellTransientState()

    struct State {
        var metadataEntriesExpanded = false
        var metadataBlocksExpanded = false
        var checklistInlineAddActive = false
        var checklistEditingItemId: UUID?
    }

    private var states: [UUID: State] = [:]

    private struct Observer {
        weak var owner: AnyObject?
        let handler: (UUID) -> Void
    }

    private var observers: [Observer] = []

    /// Registers a change handler for the owner's lifetime (weakly held, so
    /// one table controller per window can observe without unsubscription).
    func addObserver(owner: AnyObject, handler: @escaping (UUID) -> Void) {
        observers.removeAll { $0.owner == nil }
        observers.append(Observer(owner: owner, handler: handler))
    }

    func state(for workspaceId: UUID) -> State {
        states[workspaceId] ?? State()
    }

    func update(_ workspaceId: UUID, _ mutate: (inout State) -> Void) {
        var state = states[workspaceId] ?? State()
        mutate(&state)
        states[workspaceId] = state
        observers.removeAll { $0.owner == nil }
        for observer in observers {
            observer.handler(workspaceId)
        }
    }
}
