import AppKit
import Bonsplit
import Foundation
import CmuxTerminal

enum FileDropResolvedBehavior: Equatable {
    case text
    case preview

    var inverted: FileDropResolvedBehavior {
        switch self {
        case .text:
            return .preview
        case .preview:
            return .text
        }
    }
}

enum FileDropDefaultBehavior: String, CaseIterable, Identifiable {
    case text
    case preview

    var id: String { rawValue }

    var resolvedBehavior: FileDropResolvedBehavior {
        switch self {
        case .text:
            return .text
        case .preview:
            return .preview
        }
    }

    var displayName: String {
        switch self {
        case .text:
            return String(localized: "settings.app.fileDrop.defaultBehavior.text", defaultValue: "Drop path text")
        case .preview:
            return String(localized: "settings.app.fileDrop.defaultBehavior.preview", defaultValue: "Open file preview")
        }
    }

    var settingsSubtitle: String {
        switch self {
        case .text:
            return String(
                localized: "settings.app.fileDrop.defaultBehavior.text.subtitle",
                defaultValue: "Over terminals and editors, dragging files inserts shell-escaped paths. Hold Shift to open a file preview or split."
            )
        case .preview:
            return String(
                localized: "settings.app.fileDrop.defaultBehavior.preview.subtitle",
                defaultValue: "Dragging files opens previews or split panes. Hold Shift over terminals and editors to insert path text."
            )
        }
    }
}

enum FileDropTextDestinationKind: Equatable {
    case terminal
    case editor

    func hintText(for alternateBehavior: FileDropResolvedBehavior) -> String? {
        switch alternateBehavior {
        case .text:
            switch self {
            case .terminal:
                return String(
                    localized: "fileDrop.holdShiftDropIntoTerminal",
                    defaultValue: "Hold Shift to drop into terminal"
                )
            case .editor:
                return String(
                    localized: "fileDrop.holdShiftDropIntoEditor",
                    defaultValue: "Hold Shift to drop into editor"
                )
            }
        case .preview:
            return String(
                localized: "fileDrop.holdShiftOpenAsSplit",
                defaultValue: "Hold Shift to open as split"
            )
        }
    }
}

enum FileDropBehaviorSettings {
    static let defaultBehaviorKey = "fileDrop.defaultBehavior"
    static let defaultBehavior: FileDropDefaultBehavior = .text

    static func behavior(for rawValue: String?) -> FileDropDefaultBehavior {
        FileDropDefaultBehavior(rawValue: rawValue ?? "") ?? defaultBehavior
    }

    static func behavior(defaults: UserDefaults = .standard) -> FileDropDefaultBehavior {
        behavior(for: defaults.string(forKey: defaultBehaviorKey))
    }
}

@MainActor
enum FileDropTextDropController {
    static func panelIdForTerminalDropFocus(
        terminalSurfaceId: UUID,
        workspace: Workspace
    ) -> UUID? {
        if workspace.panels[terminalSurfaceId] != nil {
            return terminalSurfaceId
        }
        return workspace.panelIdFromSurfaceId(TabID(uuid: terminalSurfaceId))
    }

    @discardableResult
    static func performPanelTextDrop(
        workspace: Workspace,
        panelId: UUID,
        focusIntent: PanelFocusIntent,
        window: NSWindow?,
        insert: () -> Bool
    ) -> Bool {
        guard insert() else { return false }
        focusPanelAfterSuccessfulTextDrop(
            workspace: workspace,
            panelId: panelId,
            focusIntent: focusIntent,
            window: window
        )
        return true
    }

    @discardableResult
    static func performTerminalFileDrop(
        workspace: Workspace,
        panelId: UUID,
        hostedView: GhosttySurfaceScrollView,
        urls: [URL],
        window: NSWindow?
    ) -> Bool {
        performPanelTextDrop(
            workspace: workspace,
            panelId: panelId,
            focusIntent: .terminal(.surface),
            window: window,
            insert: {
                hostedView.handleDroppedURLs(urls)
            }
        )
    }

    @discardableResult
    static func performTerminalFileDrop(
        terminal: GhosttyNSView,
        urls: [URL]
    ) -> Bool {
        guard let workspaceId = terminal.tabId,
              let terminalSurfaceId = terminal.terminalSurface?.id,
              let workspace = AppDelegate.shared?.workspaceFor(tabId: workspaceId),
              let panelId = panelIdForTerminalDropFocus(
                terminalSurfaceId: terminalSurfaceId,
                workspace: workspace
              ) else {
            return terminal.handleDroppedFileURLs(urls)
        }
        return performPanelTextDrop(
            workspace: workspace,
            panelId: panelId,
            focusIntent: .terminal(.surface),
            window: terminal.window,
            insert: {
                terminal.handleDroppedFileURLs(urls)
            }
        )
    }

    static func focusPanelAfterSuccessfulTextDrop(
        workspace: Workspace,
        panelId: UUID,
        focusIntent: PanelFocusIntent,
        window: NSWindow?
    ) {
        AppDelegate.shared?.noteMainPanelKeyboardFocusIntent(
            workspaceId: workspace.id,
            panelId: panelId,
            in: window
        )
        workspace.focusPanel(panelId, focusIntent: focusIntent)
        _ = workspace.panels[panelId]?.restoreFocusIntent(focusIntent)
    }
}

enum DragOverlayRoutingPolicy {
    static let bonsplitTabTransferType = NSPasteboard.PasteboardType("com.splittabbar.tabtransfer")
    static let filePreviewTransferType = NSPasteboard.PasteboardType("com.cmux.filepreview.transfer")
    static let sidebarTabReorderType = NSPasteboard.PasteboardType(SidebarTabDragPayload.typeIdentifier)

    static func hasBonsplitTabTransfer(_ pasteboardTypes: [NSPasteboard.PasteboardType]?) -> Bool {
        guard let pasteboardTypes else { return false }
        return pasteboardTypes.contains(bonsplitTabTransferType)
    }

    static func hasFilePreviewTransfer(_ pasteboardTypes: [NSPasteboard.PasteboardType]?) -> Bool {
        guard let pasteboardTypes else { return false }
        return pasteboardTypes.contains(filePreviewTransferType)
    }

    static func hasSidebarTabReorder(_ pasteboardTypes: [NSPasteboard.PasteboardType]?) -> Bool {
        guard let pasteboardTypes else { return false }
        return pasteboardTypes.contains(sidebarTabReorderType)
    }

    static func hasFileURL(_ pasteboardTypes: [NSPasteboard.PasteboardType]?) -> Bool {
        PasteboardFileURLReader.hasFileURLType(pasteboardTypes ?? [])
    }

    static func hasFileDropPayload(_ pasteboardTypes: [NSPasteboard.PasteboardType]?) -> Bool {
        hasFileURL(pasteboardTypes) || hasFilePreviewTransfer(pasteboardTypes)
    }

    /// Returns whether a file drop payload is live rather than residual.
    ///
    /// Finder drops are identified by their file URL. File-preview drags also
    /// publish a file URL, but their private transfer type is only accepted
    /// while the process-local capability registry still resolves it.
    @MainActor
    static func hasLiveFileDropPayload(from pasteboard: NSPasteboard) -> Bool {
        let types = pasteboard.types
        guard hasFileDropPayload(types) else { return false }
        // A real Finder file URL remains valid even if AppKit leaves a stale
        // private preview UTI on the same pasteboard. Only preview-only
        // payloads need a live in-process capability.
        if hasFileURL(types) { return true }
        return AppDelegate.shared?.liveTabDragCapabilityResolver.resolve(from: pasteboard) != nil
    }

    @MainActor
    static func fileURLs(from pasteboard: NSPasteboard) -> [URL] {
        guard hasLiveFileDropPayload(from: pasteboard) else { return [] }
        let fileURLs = PasteboardFileURLReader.fileURLs(from: pasteboard)
        if !fileURLs.isEmpty {
            return fileURLs
        }
        guard let dragId = FilePreviewDragPasteboardWriter.dragID(from: pasteboard),
              let entry = FilePreviewDragRegistry.shared.entry(id: dragId) else {
            return []
        }
        return [URL(fileURLWithPath: entry.filePath).standardizedFileURL]
    }

    static func textDropOperation(pasteboardTypes: [NSPasteboard.PasteboardType]?) -> NSDragOperation {
        hasFilePreviewTransfer(pasteboardTypes) ? .move : .copy
    }

    @MainActor
    static var currentModifierFlags: NSEvent.ModifierFlags {
        mergedModifierFlags(
            appKitFlags: NSApp.currentEvent?.modifierFlags ?? NSEvent.modifierFlags,
            cgEventFlags: CGEventSource.flagsState(.combinedSessionState)
        )
    }

    static func mergedModifierFlags(
        appKitFlags: NSEvent.ModifierFlags,
        cgEventFlags: CGEventFlags
    ) -> NSEvent.ModifierFlags {
        var flags = appKitFlags
        if cgEventFlags.contains(.maskShift) {
            flags.insert(.shift)
        }
        if cgEventFlags.contains(.maskCommand) {
            flags.insert(.command)
        }
        if cgEventFlags.contains(.maskAlternate) {
            flags.insert(.option)
        }
        if cgEventFlags.contains(.maskControl) {
            flags.insert(.control)
        }
        if cgEventFlags.contains(.maskAlphaShift) {
            flags.insert(.capsLock)
        }
        if cgEventFlags.contains(.maskSecondaryFn) {
            flags.insert(.function)
        }
        return flags
    }

    static func resolvedFileDropBehavior(
        pasteboardTypes: [NSPasteboard.PasteboardType]?,
        modifierFlags: NSEvent.ModifierFlags,
        canDropAsText: Bool = true,
        defaultBehavior: FileDropDefaultBehavior = FileDropBehaviorSettings.behavior()
    ) -> FileDropResolvedBehavior? {
        guard hasFileDropPayload(pasteboardTypes) else { return nil }
        guard canDropAsText else { return .preview }
        let behavior = defaultBehavior.resolvedBehavior
        return modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.shift)
            ? behavior.inverted
            : behavior
    }

    static func shouldRouteFileDropToTextDestination(
        pasteboardTypes: [NSPasteboard.PasteboardType]?,
        modifierFlags: NSEvent.ModifierFlags,
        canDropAsText: Bool = true,
        defaultBehavior: FileDropDefaultBehavior = FileDropBehaviorSettings.behavior()
    ) -> Bool {
        resolvedFileDropBehavior(
            pasteboardTypes: pasteboardTypes,
            modifierFlags: modifierFlags,
            canDropAsText: canDropAsText,
            defaultBehavior: defaultBehavior
        ) == .text
    }

    static func alternateFileDropBehaviorForShiftHint(
        pasteboardTypes: [NSPasteboard.PasteboardType]?,
        modifierFlags: NSEvent.ModifierFlags,
        canDropAsText: Bool = true,
        defaultBehavior: FileDropDefaultBehavior = FileDropBehaviorSettings.behavior()
    ) -> FileDropResolvedBehavior? {
        guard hasFileDropPayload(pasteboardTypes) else { return nil }
        guard canDropAsText else { return nil }
        guard !modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.shift) else { return nil }
        return defaultBehavior.resolvedBehavior.inverted
    }

    static func shouldCaptureFileDropDestination(
        pasteboardTypes: [NSPasteboard.PasteboardType]?,
        hasLocalDraggingSource: Bool
    ) -> Bool {
        // The window overlay delegates Finder/sidebar files to pane-level Bonsplit targets.
        _ = hasLocalDraggingSource
        guard hasFileDropPayload(pasteboardTypes) else { return false }
        return true
    }

    static func shouldCaptureFileDropDestination(
        pasteboardTypes: [NSPasteboard.PasteboardType]?
    ) -> Bool {
        shouldCaptureFileDropDestination(
            pasteboardTypes: pasteboardTypes,
            hasLocalDraggingSource: false
        )
    }

    static func shouldCaptureFileDropOverlay(
        pasteboardTypes: [NSPasteboard.PasteboardType]?,
        eventType: NSEvent.EventType?
    ) -> Bool {
        guard WindowInputRoutingContext.allowsFileDropOverlayHitTesting(eventType: eventType) else { return false }
        guard shouldCaptureFileDropDestination(pasteboardTypes: pasteboardTypes) else { return false }
        return true
    }

    static func shouldPassThroughPortalHitTesting(
        pasteboardTypes: [NSPasteboard.PasteboardType]?,
        eventType: NSEvent.EventType?,
        hasActiveDropDrag: Bool = false,
        hasLiveTabTransfer: Bool = false
    ) -> Bool {
        let routingContext = WindowInputRoutingContext(eventType: eventType)
        let hasTabTransfer = hasBonsplitTabTransfer(pasteboardTypes)
            && hasLiveTabTransfer
        let hasLiveFilePreviewTransfer = hasFilePreviewTransfer(pasteboardTypes)
            && hasLiveTabTransfer
        switch routingContext.eventKind {
        case .pointerDrag:
            return hasTabTransfer
                || hasLiveFilePreviewTransfer
        case .pointerHover:
            return hasTabTransfer
        case .pointerUp:
            guard hasActiveDropDrag else { return false }
            return hasTabTransfer
                || hasLiveFilePreviewTransfer
        case .noEvent, .keyboard, .pointerDown, .scroll, .appKitRouting, .other:
            return false
        }
    }

    static func shouldPassThroughTerminalPortalHitTesting(
        pasteboardTypes: [NSPasteboard.PasteboardType]?,
        eventType: NSEvent.EventType?,
        hasActiveDropDrag: Bool = false,
        hasLiveTabTransfer: Bool = false
    ) -> Bool {
        let routingContext = WindowInputRoutingContext(eventType: eventType)
        guard routingContext.allowsTerminalPortalDragRouting else { return false }
        switch routingContext.eventKind {
        case .pointerDrag:
            return shouldPassThroughPortalHitTesting(
                pasteboardTypes: pasteboardTypes,
                eventType: eventType,
                hasActiveDropDrag: hasActiveDropDrag,
                hasLiveTabTransfer: hasLiveTabTransfer
            ) || hasFileURL(pasteboardTypes)
        case .pointerUp:
            return shouldPassThroughPortalHitTesting(
                pasteboardTypes: pasteboardTypes,
                eventType: eventType,
                hasActiveDropDrag: hasActiveDropDrag,
                hasLiveTabTransfer: hasLiveTabTransfer
            )
        case .noEvent, .keyboard, .pointerDown, .pointerHover, .scroll, .appKitRouting, .other:
            return false
        }
    }
}
