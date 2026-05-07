import AppKit
import Foundation
import WebKit

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

enum FileDropTextInsertion {
    static func insert(_ text: String, into webView: WKWebView, at windowPoint: NSPoint) -> Bool {
        let webPoint = webView.convert(windowPoint, from: nil)
        let domY = webView.isFlipped ? webPoint.y : (webView.bounds.height - webPoint.y)
        guard let payload = jsonLiteral([
            "x": Double(max(0, min(webPoint.x, webView.bounds.width))),
            "y": Double(max(0, min(domY, webView.bounds.height))),
            "text": text
        ]) else {
            return false
        }

        let script = """
        (() => {
          const payload = \(payload);
          const textInputTypes = new Set(["", "email", "number", "password", "search", "tel", "text", "url"]);
          const isTextInput = (element) => {
            if (!element || element.disabled || element.readOnly) return false;
            const tag = element.tagName;
            if (tag === "TEXTAREA") return true;
            if (tag !== "INPUT") return false;
            return textInputTypes.has((element.getAttribute("type") || "text").toLowerCase());
          };
          const editableFrom = (element) => {
            for (let node = element; node && node !== document; node = node.parentElement) {
              if (isTextInput(node)) return node;
              if (node.isContentEditable) return node;
            }
            return null;
          };
          const dispatchInput = (element, data) => {
            try {
              element.dispatchEvent(new InputEvent("input", {
                bubbles: true,
                composed: true,
                inputType: "insertText",
                data
              }));
            } catch (_) {
              element.dispatchEvent(new Event("input", { bubbles: true }));
            }
          };
          const pointElement = document.elementFromPoint(payload.x, payload.y);
          const target = editableFrom(pointElement) || editableFrom(document.activeElement);
          if (!target) return false;
          target.focus({ preventScroll: true });
          if (isTextInput(target)) {
            const start = target.selectionStart ?? target.value.length;
            const end = target.selectionEnd ?? start;
            if (typeof target.setRangeText === "function") {
              target.setRangeText(payload.text, start, end, "end");
            } else {
              target.value = target.value.slice(0, start) + payload.text + target.value.slice(end);
              const caret = start + payload.text.length;
              target.setSelectionRange?.(caret, caret);
            }
            dispatchInput(target, payload.text);
            return true;
          }

          let range = null;
          if (document.caretRangeFromPoint) {
            range = document.caretRangeFromPoint(payload.x, payload.y);
          } else if (document.caretPositionFromPoint) {
            const position = document.caretPositionFromPoint(payload.x, payload.y);
            if (position) {
              range = document.createRange();
              range.setStart(position.offsetNode, position.offset);
            }
          }
          const selection = window.getSelection();
          if (range) {
            selection.removeAllRanges();
            selection.addRange(range);
          }
          if (!selection.rangeCount) {
            target.appendChild(document.createTextNode(payload.text));
            dispatchInput(target, payload.text);
            return true;
          }
          range = selection.getRangeAt(0);
          range.deleteContents();
          const node = document.createTextNode(payload.text);
          range.insertNode(node);
          range.setStartAfter(node);
          range.setEndAfter(node);
          selection.removeAllRanges();
          selection.addRange(range);
          dispatchInput(target, payload.text);
          return true;
        })();
        """
        webView.evaluateJavaScript(script)
        return true
    }

    private static func jsonLiteral(_ object: [String: Any]) -> String? {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: []),
              let string = String(data: data, encoding: .utf8) else {
            return nil
        }
        return string
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

    static func fileURLs(from pasteboard: NSPasteboard) -> [URL] {
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
