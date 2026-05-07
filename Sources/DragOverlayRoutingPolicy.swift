import AppKit
import Foundation

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
                defaultValue: "Dragging files inserts shell-escaped paths. Hold Shift to open a file preview or split."
            )
        case .preview:
            return String(
                localized: "settings.app.fileDrop.defaultBehavior.preview.subtitle",
                defaultValue: "Dragging files opens previews or split panes. Hold Shift to insert path text."
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

    static func fileURLs(from pasteboard: NSPasteboard) -> [URL] {
        PasteboardFileURLReader.fileURLs(from: pasteboard)
    }

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
        defaultBehavior: FileDropDefaultBehavior = FileDropBehaviorSettings.behavior()
    ) -> FileDropResolvedBehavior? {
        guard hasFileURL(pasteboardTypes) else { return nil }
        let behavior = defaultBehavior.resolvedBehavior
        return modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.shift)
            ? behavior.inverted
            : behavior
    }

    static func shouldRouteFileDropToTextDestination(
        pasteboardTypes: [NSPasteboard.PasteboardType]?,
        modifierFlags: NSEvent.ModifierFlags,
        defaultBehavior: FileDropDefaultBehavior = FileDropBehaviorSettings.behavior()
    ) -> Bool {
        resolvedFileDropBehavior(
            pasteboardTypes: pasteboardTypes,
            modifierFlags: modifierFlags,
            defaultBehavior: defaultBehavior
        ) == .text
    }

    static func alternateFileDropBehaviorForShiftHint(
        pasteboardTypes: [NSPasteboard.PasteboardType]?,
        modifierFlags: NSEvent.ModifierFlags,
        defaultBehavior: FileDropDefaultBehavior = FileDropBehaviorSettings.behavior()
    ) -> FileDropResolvedBehavior? {
        guard hasFileURL(pasteboardTypes) else { return nil }
        guard !modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.shift) else { return nil }
        return defaultBehavior.resolvedBehavior.inverted
    }

    static func shouldCaptureFileDropDestination(
        pasteboardTypes: [NSPasteboard.PasteboardType]?,
        hasLocalDraggingSource: Bool
    ) -> Bool {
        // The window overlay delegates Finder/sidebar files to pane-level Bonsplit targets.
        _ = hasLocalDraggingSource
        guard hasFileURL(pasteboardTypes) else { return false }
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
        guard shouldCaptureFileDropDestination(pasteboardTypes: pasteboardTypes) else { return false }
        guard isDragMouseEvent(eventType) else { return false }
        return true
    }

    static func shouldCaptureSidebarExternalOverlay(
        hasSidebarDragState: Bool,
        pasteboardTypes: [NSPasteboard.PasteboardType]?
    ) -> Bool {
        guard hasSidebarDragState else { return false }
        return hasSidebarTabReorder(pasteboardTypes)
    }

    static func shouldCaptureSidebarExternalOverlay(
        draggedTabId: UUID?,
        pasteboardTypes: [NSPasteboard.PasteboardType]?
    ) -> Bool {
        shouldCaptureSidebarExternalOverlay(
            hasSidebarDragState: draggedTabId != nil,
            pasteboardTypes: pasteboardTypes
        )
    }

    static func shouldPassThroughPortalHitTesting(
        pasteboardTypes: [NSPasteboard.PasteboardType]?,
        eventType: NSEvent.EventType?
    ) -> Bool {
        guard isPortalDragEvent(eventType) else { return false }
        return hasBonsplitTabTransfer(pasteboardTypes)
            || hasFilePreviewTransfer(pasteboardTypes)
            || hasSidebarTabReorder(pasteboardTypes)
    }

    static func shouldPassThroughTerminalPortalHitTesting(
        pasteboardTypes: [NSPasteboard.PasteboardType]?,
        eventType: NSEvent.EventType?
    ) -> Bool {
        guard isPortalDragEvent(eventType) else { return false }
        return shouldPassThroughPortalHitTesting(
            pasteboardTypes: pasteboardTypes,
            eventType: eventType
        ) || hasFileURL(pasteboardTypes)
    }

    private static func isDragMouseEvent(_ eventType: NSEvent.EventType?) -> Bool {
        eventType == .leftMouseDragged
            || eventType == .rightMouseDragged
            || eventType == .otherMouseDragged
    }

    private static func isPortalDragEvent(_ eventType: NSEvent.EventType?) -> Bool {
        guard let eventType else { return false }
        switch eventType {
        case .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            return true
        default:
            return false
        }
    }
}
