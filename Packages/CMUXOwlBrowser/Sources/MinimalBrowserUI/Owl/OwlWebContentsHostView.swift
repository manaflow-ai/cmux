import AppKit
import MinimalBrowserCore
import OwlMojoBindingsGenerated
import QuartzCore
import SwiftUI

private let owlWebContentFallbackColor = NSColor.white.cgColor

struct OwlWebContentsHostRepresentable: NSViewRepresentable {
    let tabID: BrowserTab.ID
    let engine: BrowserEngine
    let webContentFocusRequestID: UUID?
    let automationKeyboardInputSourceID: String?

    func makeNSView(context: Context) -> OwlWebContentsHostView {
        OwlWebContentsHostView(
            tabID: tabID,
            engine: engine,
            automationKeyboardInputSourceID: automationKeyboardInputSourceID
        )
    }

    func updateNSView(_ view: OwlWebContentsHostView, context: Context) {
        view.update(
            tabID: tabID,
            engine: engine,
            automationKeyboardInputSourceID: automationKeyboardInputSourceID
        )
        view.applyWebContentFocusRequest(webContentFocusRequestID)
    }

    static func dismantleNSView(_ nsView: OwlWebContentsHostView, coordinator: ()) {
        nsView.detachHostedSurfaces()
    }
}

@MainActor
public final class OwlWebContentsHostView: NSView {
    private let webContentsController: OwlWebContentsController
    private let surfacePresenter = OwlSurfaceTreePresenter(fallbackColor: owlWebContentFallbackColor)
    private var mouseTrackingArea: NSTrackingArea?
    private var appliedWebContentFocusRequestID: UUID?
    private let liveResizeCoordinator = OwlLiveResizeCoordinator()
    private let cursorPresenter = OwlCursorPresenter()
    private let inputBridge = OwlInputEventBridge()
    private weak var observedEngine: BrowserEngine?
    private var observedTabID: BrowserTab.ID?
    private var renderSnapshotObservation: BrowserEngineRenderSnapshotObservation?
    private let hostOracleBandView: ResizeVisualOracleBandView?
    private var pendingWebContentFocusRequestID: UUID?
    private var markedText = ""
    private var markedTextRange = NSRange(location: NSNotFound, length: 0)
    private var markedSelectedRange = NSRange(location: 0, length: 0)
    private var handlingTextInputKeyDown = false
    private var hadMarkedTextAtKeyDown = false
    private var keyDownInsertedText = ""
    private var keyDownChangedComposition = false
    private var keyDownShouldFinishComposition = false
    private var automationKeyboardInputSourceID: String?
    private var lastRecordedAutomationInputSourceState: String?
    private lazy var textInputContext = NSTextInputContext(client: self)
#if DEBUG
    private var keyboardFocusOverrideForTesting: Bool?
    private var interpretKeyEventsOverrideForTesting: (([NSEvent]) -> Void)?
    var browserCursorForTesting: OwlFreshCursorInfo {
        cursorPresenter.currentCursor
    }

    func nativeCursorForTesting(_ cursor: OwlFreshCursorInfo) -> NSCursor {
        cursorPresenter.nativeCursor(for: cursor)
    }

    var surfaceRootLayerForTesting: CALayer {
        surfacePresenter.rootLayer
    }
#endif

    public init(
        tabID: BrowserTab.ID,
        engine: BrowserEngine,
        automationKeyboardInputSourceID: String? = nil
    ) {
        self.automationKeyboardInputSourceID = automationKeyboardInputSourceID
        self.webContentsController = OwlWebContentsController(tabID: tabID, engine: engine)
        if ResizeVisualOracle.enabled {
            hostOracleBandView = ResizeVisualOracleBandView(color: ResizeVisualOracle.hostBandColor)
        } else {
            hostOracleBandView = nil
        }
        super.init(frame: .zero)
        wantsLayer = true
        autoresizesSubviews = true
        layer?.backgroundColor = owlWebContentFallbackColor
        layer?.masksToBounds = true
        layer?.addSublayer(surfacePresenter.rootLayer)
        clipsToBounds = true
        if let hostOracleBandView {
            hostOracleBandView.autoresizingMask = []
            addSubview(hostOracleBandView)
            hostOracleBandView.layer?.zPosition = 100
        }
        observeRenderSnapshots(tabID: tabID, engine: engine)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public override var acceptsFirstResponder: Bool {
        true
    }

    public override var preservesContentDuringLiveResize: Bool {
        false
    }

    public override var inputContext: NSTextInputContext? {
        textInputContext
    }

    public override var frame: NSRect {
        didSet {
            if frame.size != oldValue.size || frame.origin != oldValue.origin {
                hostGeometryDidChange()
            }
        }
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.acceptsMouseMovedEvents = true
        refreshMouseTrackingArea()
        hostGeometryDidChange()
        applyAutomationKeyboardInputSource(trigger: "viewDidMoveToWindow")
    }

    public override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        hostGeometryDidChange()
    }

    public override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        hostGeometryDidChange()
    }

    public override func setBoundsSize(_ newSize: NSSize) {
        super.setBoundsSize(newSize)
        hostGeometryDidChange()
    }

    public override func viewWillStartLiveResize() {
        super.viewWillStartLiveResize()
        OwlGeometryDebugLogger.record("webHost.liveResizeStart", fields: geometryDebugFields())
        liveResizeCoordinator.beginLiveResize(currentViewport: currentViewport)
        hostGeometryDidChange()
    }

    public override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        OwlGeometryDebugLogger.record("webHost.liveResizeEnd.begin", fields: geometryDebugFields())
        hostGeometryDidChange(forceFlush: true)
        OwlGeometryDebugLogger.record("webHost.liveResizeEnd.end", fields: geometryDebugFields())
    }

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        refreshMouseTrackingArea()
    }

    public override func layout() {
        super.layout()
        layoutHostOracleBand()
        applyPendingWebContentFocusRequestIfPossible()
        hostGeometryDidChange()
    }

    public func update(
        tabID: BrowserTab.ID,
        engine: BrowserEngine,
        automationKeyboardInputSourceID: String? = nil
    ) {
        self.automationKeyboardInputSourceID = automationKeyboardInputSourceID
        let attachmentChange = webContentsController.attach(tabID: tabID, engine: engine)
        if attachmentChange.retargetedTab {
            resetHostedLayers()
            liveResizeCoordinator.reset()
        }
        observeRenderSnapshots(tabID: tabID, engine: engine)
        hostGeometryDidChange()
        applyAutomationKeyboardInputSource(trigger: "update")
    }

    public func apply(snapshot: BrowserEngineRenderSnapshot) {
        updateLayerGeometryForCurrentBounds()
        surfacePresenter.showStatus(snapshot.errorMessage)
        if let cursor = snapshot.cursor {
            applyBrowserCursor(cursor)
        }
        if let surfaceTree = snapshot.surfaceTree {
            liveResizeCoordinator.confirm(surfaceTree: surfaceTree)
            surfacePresenter.update(surfaceTree: surfaceTree, hostView: self, actions: surfaceActions)
        } else if snapshot.contextID != 0 {
            surfacePresenter.setPrimaryContextID(snapshot.contextID)
        }
        flushHostedLayers()
    }

    public func applyWebContentFocusRequest(_ requestID: UUID?) {
        guard let requestID, appliedWebContentFocusRequestID != requestID else {
            return
        }
        pendingWebContentFocusRequestID = requestID
        needsLayout = true
    }

    public func focusWebContentForSelection() {
        if window?.firstResponder !== self {
            window?.makeFirstResponder(self)
        }
        webContentsController.setFocus(true)
        applyAutomationKeyboardInputSource(trigger: "selectionFocus")
    }

    public override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        webContentsController.setFocus(true)
        applyAutomationKeyboardInputSource(trigger: "mouseDown")
        sendMouse(event, kind: .down, button: 0, clickCount: UInt32(max(event.clickCount, 1)))
    }

    public override func mouseUp(with event: NSEvent) {
        sendMouse(event, kind: .up, button: 0, clickCount: UInt32(max(event.clickCount, 1)))
    }

    public override func rightMouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        webContentsController.setFocus(true)
        applyAutomationKeyboardInputSource(trigger: "rightMouseDown")
        sendMouse(event, kind: .down, button: 2, clickCount: UInt32(max(event.clickCount, 1)))
    }

    public override func rightMouseUp(with event: NSEvent) {
        sendMouse(event, kind: .up, button: 2, clickCount: UInt32(max(event.clickCount, 1)))
    }

    public override func mouseMoved(with event: NSEvent) {
        sendMouse(event, kind: .move, button: 0, clickCount: 0)
    }

    public override func mouseEntered(with event: NSEvent) {
        sendMouse(event, kind: .move, button: 0, clickCount: 0)
    }

    public override func mouseDragged(with event: NSEvent) {
        sendMouse(event, kind: .move, button: 0, clickCount: 0)
    }

    public override func scrollWheel(with event: NSEvent) {
        let wheelEvent = inputBridge.wheelEvent(from: event, in: self)
        OwlInputEventAuditLogger.recordWheel(
            event: event,
            host: self,
            wheel: wheelEvent
        )
        webContentsController.sendWheel(wheelEvent)
    }

    public override func keyDown(with event: NSEvent) {
        guard webContentOwnsKeyboardFocus else {
            super.keyDown(with: event)
            return
        }
        applyAutomationKeyboardInputSource(trigger: "keyDown")
        guard let mappedKeyEvent = OwlKeyEventMapper.keyEvent(from: event, keyDown: true) else {
            super.keyDown(with: event)
            return
        }
        if executeFirstEditCommand(in: mappedKeyEvent) {
            OwlInputEventAuditLogger.recordKey(name: "key.editCommandDown", event: event, host: self, key: mappedKeyEvent)
            return
        }
        let textInputOutcome = interpretTextInputKeyDownIfNeeded(event)
        let keyEvent = textInputOutcome.suppressesKeyText
            ? mappedKeyEvent.withoutTextPayload()
            : mappedKeyEvent
        OwlInputEventAuditLogger.recordKey(name: "key.down", event: event, host: self, key: keyEvent)
        webContentsController.sendKey(keyEvent)
    }

    public override func keyUp(with event: NSEvent) {
        guard webContentOwnsKeyboardFocus else {
            super.keyUp(with: event)
            return
        }
        guard let keyEvent = OwlKeyEventMapper.keyEvent(from: event, keyDown: false) else {
            super.keyUp(with: event)
            return
        }
        OwlInputEventAuditLogger.recordKey(name: "key.up", event: event, host: self, key: keyEvent)
        webContentsController.sendKey(keyEvent)
    }

    public override func flagsChanged(with event: NSEvent) {
        guard webContentOwnsKeyboardFocus else {
            super.flagsChanged(with: event)
            return
        }
        guard let keyEvent = OwlKeyEventMapper.modifierEvent(from: event) else {
            super.flagsChanged(with: event)
            return
        }
        OwlInputEventAuditLogger.recordKey(name: "key.flagsChanged", event: event, host: self, key: keyEvent)
        webContentsController.sendKey(keyEvent)
    }

    public override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard webContentOwnsKeyboardFocus,
              OwlKeyEventMapper.shouldForwardToWebContentAsKeyEquivalent(event),
              let keyEvent = OwlKeyEventMapper.keyEvent(from: event, keyDown: true) else {
            return super.performKeyEquivalent(with: event)
        }
        if executeFirstEditCommand(in: keyEvent) {
            OwlInputEventAuditLogger.recordKey(name: "key.editCommandEquivalent", event: event, host: self, key: keyEvent)
            return true
        }
        OwlInputEventAuditLogger.recordKey(name: "key.equivalent", event: event, host: self, key: keyEvent)
        sendSyntheticKeyPair(keyEvent)
        return true
    }

    public override func selectAll(_ sender: Any?) {
        guard webContentOwnsKeyboardFocus else {
            return
        }
        executeEditCommand("SelectAll")
    }

    @objc public func copy(_ sender: Any?) {
        guard webContentOwnsKeyboardFocus else {
            return
        }
        executeEditCommand("Copy")
    }

    @objc public func cut(_ sender: Any?) {
        guard webContentOwnsKeyboardFocus else {
            return
        }
        executeEditCommand("Cut")
    }

    @objc public func paste(_ sender: Any?) {
        guard webContentOwnsKeyboardFocus else {
            return
        }
        executeEditCommand("Paste")
    }

    @objc public func undo(_ sender: Any?) {
        guard webContentOwnsKeyboardFocus else {
            return
        }
        executeEditCommand("Undo")
    }

    @objc public func redo(_ sender: Any?) {
        guard webContentOwnsKeyboardFocus else {
            return
        }
        executeEditCommand("Redo")
    }

    public override func resetCursorRects() {
        super.resetCursorRects()
        cursorPresenter.addCursorRect(in: self, rect: bounds)
    }

    public override func cursorUpdate(with event: NSEvent) {
        cursorPresenter.applyCurrentIfNeeded(in: self, suppressBrowserCursor: suppressBrowserCursor)
    }

#if DEBUG
    func setKeyboardFocusOwnedForTesting(_ ownsFocus: Bool?) {
        keyboardFocusOverrideForTesting = ownsFocus
    }

    func setInterpretKeyEventsOverrideForTesting(_ override: (([NSEvent]) -> Void)?) {
        interpretKeyEventsOverrideForTesting = override
    }
#endif

    private func hostGeometryDidChange(forceFlush: Bool = false) {
        layoutHostOracleBand()
        refreshMouseTrackingArea()
        updateLayerGeometryForCurrentBounds()
        resizeWebView(forceFlush: forceFlush)
        var fields = geometryDebugFields()
        fields["forceFlush"] = OwlGeometryDebugLogger.bool(forceFlush)
        OwlGeometryDebugLogger.record("webHost.geometryDidChange", fields: fields)
    }

    private func applyPendingWebContentFocusRequestIfPossible() {
        guard let requestID = pendingWebContentFocusRequestID,
              appliedWebContentFocusRequestID != requestID,
              window != nil else {
            return
        }
        pendingWebContentFocusRequestID = nil
        appliedWebContentFocusRequestID = requestID
        window?.makeFirstResponder(self)
        webContentsController.setFocus(true)
        applyAutomationKeyboardInputSource(trigger: "focusRequest")
    }

    private func resizeWebView(forceFlush: Bool = false) {
        guard let viewport = currentViewport else {
            return
        }
        do {
            try webContentsController.resize(
                viewport: viewport,
                liveResizeCoordinator: liveResizeCoordinator,
                forceFlush: forceFlush
            )
            if forceFlush || inLiveResize || (window?.inLiveResize ?? false) {
                webContentsController.pollSurfaceUpdatesForHostGeometry()
            }
        } catch {
            webContentsController.setFocus(false)
        }
    }

    private var currentViewport: OwlHostViewport? {
        guard let window, bounds.size.width >= 1, bounds.size.height >= 1 else {
            return nil
        }
        return OwlHostViewport(size: bounds.size, scale: window.backingScaleFactor)
    }

    private func layoutHostOracleBand() {
        guard let hostOracleBandView else {
            return
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        hostOracleBandView.frame = CGRect(
            x: 0,
            y: max(0, bounds.height - 22),
            width: bounds.width,
            height: 4
        )
        CATransaction.commit()
    }

    private var webContentOwnsKeyboardFocus: Bool {
#if DEBUG
        if let keyboardFocusOverrideForTesting {
            return keyboardFocusOverrideForTesting
        }
#endif
        guard let firstResponder = window?.firstResponder else {
            return false
        }
        if firstResponder === self {
            return true
        }
        guard let responderView = firstResponder as? NSView else {
            return false
        }
        return responderView == self || responderView.isDescendant(of: self)
    }

    private func refreshMouseTrackingArea() {
        if let mouseTrackingArea {
            removeTrackingArea(mouseTrackingArea)
            self.mouseTrackingArea = nil
        }
        guard !bounds.isEmpty else {
            return
        }
        let trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.activeInActiveApp, .inVisibleRect, .mouseEnteredAndExited, .mouseMoved, .cursorUpdate],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
        mouseTrackingArea = trackingArea
    }

    private func sendMouse(
        _ event: NSEvent,
        kind: OwlFreshMouseKind,
        button: UInt32,
        clickCount: UInt32
    ) {
        let mouseEvent = inputBridge.mouseEvent(
            from: event,
            in: self,
            kind: kind,
            button: button,
            clickCount: clickCount
        )
        OwlInputEventAuditLogger.recordMouse(
            kind: kind,
            event: event,
            host: self,
            browserX: mouseEvent.x,
            browserY: mouseEvent.y
        )
        webContentsController.sendMouse(mouseEvent)
    }

    private func executeFirstEditCommand(in keyEvent: OwlFreshKeyEvent) -> Bool {
        guard let command = keyEvent.editCommands.first, isBrowserEditCommand(command) else {
            return false
        }
        executeEditCommand(command)
        return true
    }

    private func executeEditCommand(_ command: String) {
        webContentsController.executeEditCommand(command)
    }

    private func isBrowserEditCommand(_ command: String) -> Bool {
        switch command {
        case "SelectAll", "Copy", "Cut", "Paste", "Undo", "Redo":
            return true
        default:
            return false
        }
    }

    private func sendSyntheticKeyPair(_ keyDownEvent: OwlFreshKeyEvent) {
        webContentsController.sendKey(keyDownEvent)
        webContentsController.sendKey(OwlFreshKeyEvent(
            keyDown: false,
            keyCode: keyDownEvent.keyCode,
            text: "",
            modifiers: keyDownEvent.modifiers,
            editCommands: []
        ))
    }

    private func sendComposition(_ event: OwlFreshCompositionEvent) {
        OwlInputEventAuditLogger.recordComposition(event, host: self)
        webContentsController.sendComposition(event)
    }

    private func applyAutomationKeyboardInputSource(trigger: String) {
        guard let sourceID = automationKeyboardInputSourceID,
              !sourceID.isEmpty else {
            return
        }
        let context = inputContext
        let activated = window?.firstResponder === self
        if activated {
            context?.activate()
        }
        let before = context?.selectedKeyboardInputSource
        context?.selectedKeyboardInputSource = sourceID
        let after = context?.selectedKeyboardInputSource
        let state = "\(trigger)|\(before ?? "")|\(after ?? "")"
        guard state != lastRecordedAutomationInputSourceState else {
            return
        }
        lastRecordedAutomationInputSourceState = state
        OwlInputEventAuditLogger.recordTextInputContext(
            name: "textInputContext.keyboardInputSource",
            host: self,
            trigger: trigger,
            requestedInputSourceID: sourceID,
            activated: activated,
            availableInputSourceIDs: context?.keyboardInputSources ?? [],
            selectedInputSourceBefore: before,
            selectedInputSourceAfter: after
        )
    }

    private func interpretTextInputKeyDownIfNeeded(_ event: NSEvent) -> TextInputKeyDownOutcome {
        guard shouldInterpretTextInputKeyDown(event) else {
            return TextInputKeyDownOutcome(suppressesKeyText: false)
        }

        handlingTextInputKeyDown = true
        hadMarkedTextAtKeyDown = hasMarkedText()
        keyDownInsertedText = ""
        keyDownChangedComposition = false
        keyDownShouldFinishComposition = false
#if DEBUG
        if let interpretKeyEventsOverrideForTesting {
            interpretKeyEventsOverrideForTesting([event])
        } else {
            interpretKeyEvents([event])
        }
#else
        interpretKeyEvents([event])
#endif

        let insertedText = keyDownInsertedText
        let changedComposition = keyDownChangedComposition
        let shouldFinishComposition = keyDownShouldFinishComposition
        let hadMarkedText = hadMarkedTextAtKeyDown
        handlingTextInputKeyDown = false
        hadMarkedTextAtKeyDown = false
        keyDownInsertedText = ""
        keyDownChangedComposition = false
        keyDownShouldFinishComposition = false

        if !insertedText.isEmpty,
           shouldCommitTextFromInputContext(
               insertedText,
               event: event,
               hadMarkedText: hadMarkedText,
               changedComposition: changedComposition
           ) {
            sendComposition(OwlFreshCompositionEvent(kind: .commit, text: insertedText))
            return TextInputKeyDownOutcome(suppressesKeyText: true)
        }
        if shouldFinishComposition {
            sendComposition(OwlFreshCompositionEvent(kind: .finish, text: ""))
        }
        return TextInputKeyDownOutcome(suppressesKeyText: changedComposition)
    }

    private func shouldInterpretTextInputKeyDown(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown,
              !event.modifierFlags.contains(.command),
              !event.modifierFlags.contains(.control) else {
            return false
        }
        if hasMarkedText() {
            return true
        }
        if let characters = event.characters, !characters.isEmpty {
            return true
        }
        return false
    }

    private func shouldCommitTextFromInputContext(
        _ text: String,
        event: NSEvent,
        hadMarkedText: Bool,
        changedComposition: Bool
    ) -> Bool {
        if hadMarkedText || changedComposition {
            return true
        }
        return text != event.characters || (text as NSString).length != 1
    }

    private func applyBrowserCursor(_ cursor: OwlFreshCursorInfo) {
        OwlInputEventAuditLogger.recordCursor(
            cursor,
            nativeCursorName: cursorPresenter.nativeCursorName(for: cursor),
            host: self,
            suppressBrowserCursor: suppressBrowserCursor
        )
        cursorPresenter.apply(cursor, in: self, suppressBrowserCursor: suppressBrowserCursor)
    }

    private var suppressBrowserCursor: Bool {
        surfacePresenter.suppressesBrowserCursor
    }

    private func updateLayerGeometryForCurrentBounds() {
        surfacePresenter.applyHostGeometry(bounds: bounds, scale: currentBackingScale)
    }

    private func geometryDebugFields() -> [String: String] {
        var fields: [String: String] = [
            "frame": OwlGeometryDebugLogger.rect(frame),
            "bounds": OwlGeometryDebugLogger.rect(bounds),
            "scale": String(format: "%.3f", currentBackingScale),
            "inLiveResize": OwlGeometryDebugLogger.bool(inLiveResize || (window?.inLiveResize ?? false)),
            "viewport": currentViewport.map { OwlGeometryDebugLogger.size($0.size) } ?? "nil",
            "rootLayerFrame": OwlGeometryDebugLogger.rect(surfacePresenter.rootLayer.frame),
            "rootLayerBounds": OwlGeometryDebugLogger.rect(surfacePresenter.rootLayer.bounds)
        ]
        fields["windowFrame"] = window.map { OwlGeometryDebugLogger.rect($0.frame) } ?? "nil"
        surfacePresenter.debugGeometryFields(prefix: "presenter").forEach { key, value in
            fields[key] = value
        }
        return fields
    }

    private var currentBackingScale: CGFloat {
        max(window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1, 1)
    }

    private var surfaceActions: OwlSurfaceTreePresenter.Actions {
        OwlSurfaceTreePresenter.Actions(
            devToolsEnabled: webContentsController.devToolsEnabled,
            acceptPopupMenuItem: { [weak self] index in
                guard let self else {
                    return
                }
                self.webContentsController.acceptActivePopupMenuItem(index: index)
            },
            cancelPopup: { [weak self] in
                guard let self else {
                    return
                }
                self.webContentsController.cancelActivePopup()
            },
            selectFilePickerFiles: { [weak self] paths in
                guard let self else {
                    return
                }
                self.webContentsController.selectActiveFilePickerFiles(paths: paths)
            },
            cancelFilePicker: { [weak self] in
                guard let self else {
                    return
                }
                self.webContentsController.cancelActiveFilePicker()
            },
            acceptPermissionPrompt: { [weak self] in
                guard let self else {
                    return
                }
                self.webContentsController.acceptActivePermissionPrompt()
            },
            cancelPermissionPrompt: { [weak self] in
                guard let self else {
                    return
                }
                self.webContentsController.cancelActivePermissionPrompt()
            },
            submitAuthPrompt: { [weak self] username, password in
                guard let self else {
                    return
                }
                self.webContentsController.submitActiveAuthPrompt(username: username, password: password)
            },
            cancelAuthPrompt: { [weak self] in
                guard let self else {
                    return
                }
                self.webContentsController.cancelActiveAuthPrompt()
            },
            closeDevTools: { [weak self] in
                guard let self else {
                    return
                }
                self.webContentsController.closeDevTools()
            }
        )
    }

    public func flushHostedLayers() {
        surfacePresenter.flush()
    }

    public func detachHostedSurfaces() {
        webContentsController.detach()
        if let renderSnapshotObservation, let observedEngine {
            observedEngine.removeRenderSnapshotObserver(renderSnapshotObservation)
        }
        renderSnapshotObservation = nil
        observedEngine = nil
        observedTabID = nil
        resetHostedLayers()
    }

    private func resetHostedLayers() {
        surfacePresenter.reset()
    }

    private func observeRenderSnapshots(tabID: BrowserTab.ID, engine: BrowserEngine) {
        if let renderSnapshotObservation,
           observedEngine === engine {
            observedTabID = tabID
            engine.updateRenderSnapshotObserver(renderSnapshotObservation, tabID: tabID)
            return
        }
        if let renderSnapshotObservation, let observedEngine {
            observedEngine.removeRenderSnapshotObserver(renderSnapshotObservation)
        }
        observedEngine = engine
        observedTabID = tabID
        renderSnapshotObservation = engine.addRenderSnapshotObserver(for: tabID) { [weak self] snapshot in
            self?.apply(snapshot: snapshot)
        }
    }
}

extension OwlWebContentsHostView: @preconcurrency NSTextInputClient {
    public func insertText(_ string: Any, replacementRange: NSRange) {
        guard webContentOwnsKeyboardFocus else {
            return
        }
        let text = textInputString(from: string)
        clearMarkedTextState()
        if handlingTextInputKeyDown {
            keyDownInsertedText += text
            return
        }
        sendComposition(OwlFreshCompositionEvent(kind: .commit, text: text))
    }

    public func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        guard webContentOwnsKeyboardFocus else {
            return
        }
        let text = textInputString(from: string)
        let textLength = (text as NSString).length
        markedText = text
        markedTextRange = text.isEmpty
            ? NSRange(location: NSNotFound, length: 0)
            : NSRange(location: 0, length: textLength)
        markedSelectedRange = clampedRange(selectedRange, upperBound: textLength)
        keyDownChangedComposition = true
        sendComposition(OwlFreshCompositionEvent(
            kind: .set,
            text: text,
            selectionStart: UInt32(markedSelectedRange.location),
            selectionEnd: UInt32(markedSelectedRange.location + markedSelectedRange.length)
        ))
    }

    public func unmarkText() {
        guard webContentOwnsKeyboardFocus else {
            return
        }
        clearMarkedTextState()
        keyDownChangedComposition = true
        if handlingTextInputKeyDown {
            keyDownShouldFinishComposition = true
            return
        }
        sendComposition(OwlFreshCompositionEvent(kind: .finish, text: ""))
    }

    public func selectedRange() -> NSRange {
        markedSelectedRange
    }

    public func markedRange() -> NSRange {
        markedTextRange
    }

    public func hasMarkedText() -> Bool {
        markedTextRange.location != NSNotFound
    }

    public func attributedSubstring(
        forProposedRange range: NSRange,
        actualRange: NSRangePointer?
    ) -> NSAttributedString? {
        guard !markedText.isEmpty else {
            actualRange?.pointee = NSRange(location: NSNotFound, length: 0)
            return nil
        }
        let nsString = markedText as NSString
        let clamped = clampedRange(range, upperBound: nsString.length)
        actualRange?.pointee = clamped
        return NSAttributedString(string: nsString.substring(with: clamped))
    }

    public func validAttributesForMarkedText() -> [NSAttributedString.Key] {
        [.underlineStyle, .markedClauseSegment, .languageIdentifier]
    }

    public func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        actualRange?.pointee = clampedRange(range, upperBound: (markedText as NSString).length)
        let localRect = NSRect(x: bounds.minX, y: bounds.maxY, width: 1, height: 1)
        let windowRect = convert(localRect, to: nil)
        return window?.convertToScreen(windowRect) ?? windowRect
    }

    public func characterIndex(for point: NSPoint) -> Int {
        0
    }

    private func textInputString(from string: Any) -> String {
        if let attributed = string as? NSAttributedString {
            return attributed.string
        }
        if let text = string as? String {
            return text
        }
        return String(describing: string)
    }

    private func clearMarkedTextState() {
        markedText = ""
        markedTextRange = NSRange(location: NSNotFound, length: 0)
        markedSelectedRange = NSRange(location: 0, length: 0)
    }

    private func clampedRange(_ range: NSRange, upperBound: Int) -> NSRange {
        let safeUpperBound = max(upperBound, 0)
        guard range.location != NSNotFound else {
            return NSRange(location: safeUpperBound, length: 0)
        }
        let location = min(max(range.location, 0), safeUpperBound)
        let maxLength = safeUpperBound - location
        return NSRange(location: location, length: min(max(range.length, 0), maxLength))
    }
}

private struct TextInputKeyDownOutcome {
    let suppressesKeyText: Bool
}

private extension OwlFreshKeyEvent {
    func withoutTextPayload() -> OwlFreshKeyEvent {
        OwlFreshKeyEvent(
            keyDown: keyDown,
            keyCode: keyCode,
            text: "",
            modifiers: modifiers,
            editCommands: editCommands,
            nativeEventType: nativeEventType,
            nativeKeyCode: nativeKeyCode,
            isRepeat: isRepeat,
            characters: "",
            charactersIgnoringModifiers: ""
        )
    }
}
