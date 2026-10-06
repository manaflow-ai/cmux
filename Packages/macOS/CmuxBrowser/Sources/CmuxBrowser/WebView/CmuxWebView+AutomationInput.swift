public import AppKit
public import ObjectiveC
public import WebKit

/// Native input delivery for browser automation (the REPL WebKit driver).
///
/// Events go straight to WebKit's own `NSResponder` implementations, skipping
/// `CmuxWebView`'s overrides: those exist for physical input (click-to-focus
/// handoff, back/forward mouse buttons, cmux shortcut routing) and would
/// otherwise move keyboard focus away from the user's current pane. WebKit
/// turns the events into DOM events with `isTrusted === true`.
@MainActor
extension CmuxWebView {
    /// Delivers one synthesized mouse or scroll event to WebKit.
    public func deliverAutomationMouseEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown || event.type == .rightMouseDown || event.type == .otherMouseDown {
            automationContextMenuSuppression.noteAutomatedMouseDown(event)
        }
        browserNativeInputDeliveryOwner.withDispatch {
            switch event.type {
            case .leftMouseDown: super.mouseDown(with: event)
            case .leftMouseUp: super.mouseUp(with: event)
            case .leftMouseDragged: super.mouseDragged(with: event)
            case .rightMouseDown: super.rightMouseDown(with: event)
            case .rightMouseUp: super.rightMouseUp(with: event)
            case .rightMouseDragged: super.rightMouseDragged(with: event)
            case .otherMouseDown: super.otherMouseDown(with: event)
            case .otherMouseUp: super.otherMouseUp(with: event)
            case .otherMouseDragged: super.otherMouseDragged(with: event)
            case .mouseMoved:
                // WebKit ignores a plain `mouseMoved(with:)` that AppKit's
                // tracking area did not route; its testing entry point feeds
                // the same event handler (checked on macOS 26 with a stand-alone
                // WKWebView). Hover still needs an active (key) window, which
                // the REPL's render window reports.
                let simulate = NSSelectorFromString("_simulateMouseMove:")
                if responds(to: simulate) {
                    perform(simulate, with: event)
                } else {
                    super.mouseMoved(with: event)
                }
            case .scrollWheel: super.scrollWheel(with: event)
            default: break
            }
        }
    }

    /// Automated clicks whose native context menu is still expected
    /// (``BrowserAutomationContextMenuSuppression``).
    var automationContextMenuSuppression: BrowserAutomationContextMenuSuppression {
        get {
            BrowserAutomationContextMenuSuppression(
                pending: (objc_getAssociatedObject(self, Self.contextMenuSuppressionKey) as? NSNumber)?.intValue ?? 0
            )
        }
        set {
            objc_setAssociatedObject(
                self,
                Self.contextMenuSuppressionKey,
                NSNumber(value: newValue.pending),
                .OBJC_ASSOCIATION_RETAIN_NONATOMIC
            )
        }
    }

    /// Consumes one pending suppression. `willOpenMenu` calls this so the menu
    /// WebKit builds for an automated click never appears.
    func consumeAutomationContextMenuSuppression() -> Bool {
        automationContextMenuSuppression.consume()
    }

    /// Forgets automated clicks whose context menu never opened (the page
    /// prevented it), so the user's next menu is not swallowed after the
    /// automation leaves the tab.
    public func cancelPendingAutomationContextMenus() {
        automationContextMenuSuppression.cancelAll()
    }

    private static let contextMenuSuppressionKey: UnsafeRawPointer = {
        UnsafeRawPointer(Unmanaged.passUnretained(ContextMenuSuppressionKey.shared).toOpaque())
    }()

    // MARK: - HTML5 drag and drop

    /// Captures the drag WebKit starts after an automated `mouseDragged`
    /// instead of handing it to AppKit, whose drag loop follows the physical
    /// cursor. The driver then plays the destination side itself. Replacing
    /// or clearing it finishes the previous capture (its private pasteboard
    /// is emptied and released).
    public var automationDragCapture: BrowserAutomationDragCapture? {
        get { objc_getAssociatedObject(self, Self.dragCaptureKey) as? BrowserAutomationDragCapture }
        set {
            let previous = automationDragCapture
            objc_setAssociatedObject(self, Self.dragCaptureKey, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            if let previous, previous !== newValue { previous.finish() }
        }
    }

    private static let dragCaptureKey: UnsafeRawPointer = {
        UnsafeRawPointer(Unmanaged.passUnretained(DragCaptureKey.shared).toOpaque())
    }()

    /// Ends the captured drag at `windowPoint` with `operation`, firing `dragend`.
    public func endAutomationDrag(at windowPoint: NSPoint, operation: NSDragOperation) {
        let selector = NSSelectorFromString("draggingSession:endedAtPoint:operation:")
        guard responds(to: selector) else { return }
        let session = BrowserAutomationDragCapture.placeholderSession()
        let screenPoint = window?.convertPoint(toScreen: windowPoint) ?? windowPoint
        typealias EndedFunction = @convention(c) (AnyObject, Selector, NSDraggingSession, NSPoint, UInt) -> Void
        let function = unsafeBitCast(method(for: selector), to: EndedFunction.self)
        function(self, selector, session, screenPoint, operation.rawValue)
    }
}

private final class ContextMenuSuppressionKey: NSObject, @unchecked Sendable {
    static let shared = ContextMenuSuppressionKey()
}

private final class DragCaptureKey: NSObject, @unchecked Sendable {
    static let shared = DragCaptureKey()
}

/// A drag WebKit started while automation was driving the mouse.
///
/// The drag's data never touches the system's named drag pasteboard, which
/// every process of the user can read and overwrite while the driver waits
/// for WebKit: each capture has its own uniquely named pasteboard, and while
/// its window is open (``openPasteboardWindow()``, around the automated
/// `mouseDragged` events that may start the drag) WebKit's lookups of the
/// drag pasteboard get it (``BrowserReplDragPasteboardRedirect``). The window
/// closes when WebKit starts the drag, which it does after writing the
/// data, or at ``closePasteboardWindow()``. A drag WebKit starts after its
/// window closed carries no data to the drop.
@MainActor
public final class BrowserAutomationDragCapture: NSObject {
    /// Called once WebKit asks AppKit to begin the drag session.
    public var onBegin: (() -> Void)?
    /// Whether WebKit has started the drag.
    public private(set) var didBegin = false
    /// This drag's private pasteboard, which WebKit writes the drag data to
    /// and the automated drop reads.
    public let pasteboard = NSPasteboard.withUniqueName()
    private var finished = false
    /// Whether the capture ended (``finish()``); its window no longer opens.
    public var isFinished: Bool { finished }

    public override init() {
        super.init()
    }

    /// Opens this drag's pasteboard window, waiting up to 5 s for another
    /// automated drag's window to close. Returns `false` when it did not
    /// open (another drag's window stayed open, or this capture finished);
    /// the caller must not deliver the event that may start the drag then,
    /// or WebKit could write this drag's data to the other one's pasteboard.
    public func openPasteboardWindow() async -> Bool {
        guard !finished else { return false }
        let opened = await BrowserReplDragPasteboardRedirect.shared.openDragWindow(pasteboard)
        if opened, finished {
            BrowserReplDragPasteboardRedirect.shared.closeDragWindow(pasteboard)
            return false
        }
        return opened
    }

    /// Closes this drag's pasteboard window, if it is open.
    public func closePasteboardWindow() {
        BrowserReplDragPasteboardRedirect.shared.closeDragWindow(pasteboard)
    }

    /// Ends the capture: closes its window and empties and releases its
    /// pasteboard. Called when the web view's capture is replaced or cleared.
    public func finish() {
        guard !finished else { return }
        finished = true
        closePasteboardWindow()
        pasteboard.clearContents()
        pasteboard.releaseGlobally()
    }

    func begin() {
        didBegin = true
        // WebKit wrote the drag data before asking AppKit for the session.
        closePasteboardWindow()
        let callback = onBegin
        onBegin = nil
        callback?()
    }

    /// An `NSDraggingSession` that was never started. WebKit discards the
    /// session returned from `beginDraggingSession` and only passes it back to
    /// the source callbacks, which do not inspect it.
    static func placeholderSession() -> NSDraggingSession {
        let type: NSObject.Type = NSDraggingSession.self
        // swiftlint:disable:next force_cast
        return type.init() as! NSDraggingSession
    }
}

/// `NSDraggingInfo` for an automated drop onto the web view that started it.
/// Created and used on the main thread only.
public final class BrowserAutomationDraggingInfo: NSObject, NSDraggingInfo, @unchecked Sendable {
    public var draggingDestinationWindow: NSWindow?
    public var draggingSourceOperationMask: NSDragOperation = [.copy, .move, .link, .generic]
    public var draggingLocation: NSPoint
    public var draggedImageLocation: NSPoint { draggingLocation }
    public var draggedImage: NSImage? { nil }
    public var draggingPasteboard: NSPasteboard
    public var draggingSource: Any?
    public var draggingSequenceNumber: Int
    public var draggingFormation: NSDraggingFormation = .none
    public var animatesToDestination = false
    public var numberOfValidItemsForDrop = 1
    public var springLoadingHighlight: NSSpringLoadingHighlight { .none }

    @MainActor
    public init(window: NSWindow?, location: NSPoint, pasteboard: NSPasteboard, source: Any?, sequenceNumber: Int) {
        draggingDestinationWindow = window
        draggingLocation = location
        draggingPasteboard = pasteboard
        draggingSource = source
        draggingSequenceNumber = sequenceNumber
    }

    public func slideDraggedImage(to screenPoint: NSPoint) {}

    public func enumerateDraggingItems(
        options enumOpts: NSDraggingItemEnumerationOptions = [],
        for view: NSView?,
        classes classArray: [AnyClass],
        searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:],
        using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void
    ) {}

    public func resetSpringLoading() {}
}

extension CmuxWebView {
    /// While an automated drag is armed, WebKit's drag start is captured
    /// rather than handed to AppKit. Otherwise AppKit runs the normal session.
    public override func beginDraggingSession(
        with items: [NSDraggingItem],
        event: NSEvent,
        source: any NSDraggingSource
    ) -> NSDraggingSession {
        if let capture = automationDragCapture {
            capture.begin()
            return BrowserAutomationDragCapture.placeholderSession()
        }
        return super.beginDraggingSession(with: items, event: event, source: source)
    }
}

@MainActor
extension WKWebView {
    /// Delivers one REPL key event through WebKit's native keyboard path.
    ///
    /// Modifier keys update the held-modifier state of `holder` (the REPL
    /// session that sends the key) and emit `flagsChanged`; other keys carry
    /// the modifiers `holder` holds plus their own. Another session's held
    /// modifiers never reach these events. `editingCommand` is not run here;
    /// the driver runs it after key-down.
    @discardableResult
    public func replayBrowserReplKeyStroke(
        _ stroke: BrowserReplKeyStroke,
        keyDown: Bool,
        heldBy holder: String = ""
    ) -> BrowserKeyboardReplayResult {
        if let modifierKey = stroke.modifierKey {
            let native = BrowserKeyboardNativeKey(
                keyCode: stroke.keyCode,
                location: stroke.location,
                modifiers: modifierKey,
                modifierKey: modifierKey
            )
            return replayBrowserNativeModifier(native, keyDown: keyDown, heldBy: holder)
        }
        let flags = stroke.modifierFlags.union(browserNativeInputDeliveryOwner.activeModifierFlags(heldBy: holder))
        let specification = SyntheticKeySpecification(
            storedKey: stroke.charactersIgnoringModifiers,
            keyCode: stroke.keyCode,
            modifierFlags: flags,
            characters: stroke.characters,
            charactersIgnoringModifiers: stroke.charactersIgnoringModifiers
        )
        return replayBrowserKeyboardSpecification(
            specification,
            action: keyDown ? .keyDown : .keyUp,
            characters: stroke.characters.isEmpty ? nil : stroke.characters,
            marksBrowserAutomation: true
        )
    }

    /// Forgets that `holder` holds `stroke`'s modifier, without sending
    /// the page an event; its later automated keys no longer carry it.
    public func forgetBrowserReplModifier(_ stroke: BrowserReplKeyStroke, heldBy holder: String = "") {
        guard stroke.modifierKey != nil else { return }
        browserNativeInputDeliveryOwner.removeModifier(for: stroke.keyCode, heldBy: holder)
    }

    /// Releases every modifier the automation left held, for every holder.
    public func releaseBrowserReplModifiers() {
        browserNativeInputDeliveryOwner.removeAllModifiers()
    }
}
