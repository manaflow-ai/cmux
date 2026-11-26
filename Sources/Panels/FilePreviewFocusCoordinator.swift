import AppKit
import Carbon.HIToolbox

final class FilePreviewFocusCoordinator {
    private struct Endpoint {
        weak var root: NSView?
        weak var primaryResponder: NSView?
    }

    private var endpoints: [FilePreviewPanelFocusIntent: Endpoint] = [:]
    private(set) var preferredIntent: FilePreviewPanelFocusIntent
    private var pendingIntent: FilePreviewPanelFocusIntent?

    init(preferredIntent: FilePreviewPanelFocusIntent) {
        self.preferredIntent = preferredIntent
    }

    func register(root: NSView, primaryResponder: NSView, intent: FilePreviewPanelFocusIntent) {
        endpoints[intent] = Endpoint(root: root, primaryResponder: primaryResponder)
        fulfillPendingFocusIfNeeded(for: intent)
    }

    func unregisterAll() {
        endpoints.removeAll()
        pendingIntent = nil
    }

    func notePreferredIntent(_ intent: FilePreviewPanelFocusIntent) {
        preferredIntent = intent
    }

    func focus(_ intent: FilePreviewPanelFocusIntent) -> Bool {
        preferredIntent = intent
        guard let endpoint = endpoint(for: intent) else {
            pendingIntent = intent
            return false
        }
        guard let window = endpoint.window,
              window.makeFirstResponder(endpoint) else {
            pendingIntent = intent
            return false
        }
        pendingIntent = nil
        return true
    }

    func ownedIntent(for responder: NSResponder, in window: NSWindow) -> FilePreviewPanelFocusIntent? {
        guard let match = ownedEndpoint(for: responder),
              match.endpoint.root?.window === window else {
            return nil
        }
        return match.intent
    }

    func ownedIntent(for responder: NSResponder) -> FilePreviewPanelFocusIntent? {
        ownedEndpoint(for: responder)?.intent
    }

    func endpoint(for intent: FilePreviewPanelFocusIntent) -> NSView? {
        guard let endpoint = endpoints[intent],
              let primaryResponder = endpoint.primaryResponder else {
            return nil
        }
        return primaryResponder
    }

    private func fulfillPendingFocusIfNeeded(for intent: FilePreviewPanelFocusIntent) {
        guard pendingIntent == intent else { return }
        fulfillPendingFocusIfNeeded()
    }

    func fulfillPendingFocusIfNeeded() {
        guard let intent = pendingIntent else { return }
        _ = focus(intent)
    }

    private func ownedEndpoint(for responder: NSResponder) -> (
        intent: FilePreviewPanelFocusIntent,
        endpoint: Endpoint
    )? {
        var bestMatch: (intent: FilePreviewPanelFocusIntent, endpoint: Endpoint, distance: Int)?
        for (intent, endpoint) in endpoints {
            guard let root = endpoint.root,
                  let distance = containmentDistance(from: responder, to: root) else {
                continue
            }
            if bestMatch == nil || distance < bestMatch!.distance {
                bestMatch = (intent: intent, endpoint: endpoint, distance: distance)
            }
        }
        guard let bestMatch else { return nil }
        return (intent: bestMatch.intent, endpoint: bestMatch.endpoint)
    }

    private func containmentDistance(from responder: NSResponder, to root: NSView) -> Int? {
        if responder === root {
            return 0
        }
        guard let view = responder as? NSView else { return nil }
        var current: NSView? = view
        var distance = 0
        while let next = current {
            if next === root {
                return distance
            }
            current = next.superview
            distance += 1
        }
        return nil
    }
}

enum FilePreviewPDFKeyboardAction: Equatable {
    case native
    case navigatePage(Int)
}

enum FilePreviewPDFKeyboardRouting {
    static func action(
        keyCode: UInt16,
        modifiers: NSEvent.ModifierFlags,
        region: FilePreviewPanelFocusIntent
    ) -> FilePreviewPDFKeyboardAction {
        let flags = modifiers.intersection(.deviceIndependentFlagsMask)
        guard flags.intersection([.command, .control, .option, .shift]).isEmpty else {
            return .native
        }

        guard region == .pdfThumbnails else {
            return .native
        }

        switch Int(keyCode) {
        case kVK_UpArrow, kVK_PageUp:
            return .navigatePage(-1)
        case kVK_DownArrow, kVK_PageDown:
            return .navigatePage(1)
        default:
            return .native
        }
    }

    static func action(
        for event: NSEvent,
        region: FilePreviewPanelFocusIntent
    ) -> FilePreviewPDFKeyboardAction {
        action(
            keyCode: event.keyCode,
            modifiers: event.modifierFlags,
            region: region
        )
    }
}
