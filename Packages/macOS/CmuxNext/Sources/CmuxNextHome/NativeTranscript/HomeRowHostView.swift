import AppKit
import CmuxHomeCore
import CmuxHomeRender
import CmuxNextDesign

/// Hosts the render core's root layer (flipped: the core lays out top-left)
/// and exposes its rows to accessibility: the rows are layers, so each
/// visible message is an explicit `NSAccessibilityElement` in a list.
final class HomeRowHostView: NSView {
    weak var controller: HomeController?
    /// A click on no bubble (and no drag): the host focuses its message box.
    var onEmptyClick: () -> Void = {}
    /// A click on a video bubble plays or pauses it (true when it was a video).
    var onVideoClick: (HomeHit) -> Bool = { _ in false }
    /// Cancel Upload on my pending send (the parent forwards it to the store).
    var onCancelSend: (IdempotencyKey) -> Bool = { _ in false }
    /// False while the owner is unreachable: nothing queues, so no tapback
    /// picker and no reaction actions (the parent mirrors `isSendEnabled`).
    var reactionsEnabled = true {
        didSet { if reactionsEnabled != oldValue { elements = [] } }
    }
    private var elements: [NSAccessibilityElement] = []
    /// Messages selected by a drag across rows, top to bottom.
    private(set) var selection: [HomeHit] = []
    private var dragStart: CGPoint?
    let selectionLayer = CAShapeLayer()
    static let dragThreshold: CGFloat = 3

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        setAccessibilityElement(true)
        setAccessibilityRole(.list)
        selectionLayer.actions = ["path": NSNull(), "fillColor": NSNull()]
        selectionLayer.zPosition = 1
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if selectionLayer.superlayer == nil { layer?.addSublayer(selectionLayer) }
    }

    override var acceptsFirstResponder: Bool { !selection.isEmpty }

    /// A click on a video plays it even while the window is inactive (the
    /// click that activates the window is not lost); other clicks only activate.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        guard let event, let controller, let hit = controller.hit(at: convert(event.locationInWindow, from: nil)) else { return false }
        return controller.videoState(for: hit.item, partIndex: hit.partIndex) != nil
    }

    // MARK: Selection across rows (whole messages)

    override func mouseDown(with event: NSEvent) {
        dragStart = convert(event.locationInWindow, from: nil)
        if !selection.isEmpty { select([]) }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = dragStart else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard abs(point.y - start.y) > Self.dragThreshold || abs(point.x - start.x) > Self.dragThreshold else { return }
        autoscroll(with: event)
        dragSelect(from: start, to: convert(event.locationInWindow, from: nil))
    }

    override func mouseUp(with event: NSEvent) {
        let start = dragStart
        dragStart = nil
        if !selection.isEmpty { window?.makeFirstResponder(self); return }
        let point = convert(event.locationInWindow, from: nil)
        guard let start, abs(point.y - start.y) <= Self.dragThreshold, abs(point.x - start.x) <= Self.dragThreshold else { return }
        if let hit = controller?.hit(at: point) {
            _ = onVideoClick(hit)
        } else {
            onEmptyClick()
        }
    }

    /// Selects every message whose bubble the vertical span from `a` to `b`
    /// meets (viewport points).
    func dragSelect(from a: CGPoint, to b: CGPoint) {
        let rect = CGRect(x: 0, y: min(a.y, b.y), width: bounds.width, height: max(1, abs(b.y - a.y)))
        select(controller?.hits(in: rect) ?? [])
    }

    private func select(_ hits: [HomeHit]) {
        selection = hits
        let path = CGMutablePath()
        for hit in hits { path.addRoundedRect(in: hit.bubble.insetBy(dx: -2, dy: -2), cornerWidth: 17, cornerHeight: 17) }
        selectionLayer.frame = bounds
        selectionLayer.path = path
        performWithTheme { selectionLayer.fillColor = Palette.selectionFill.cgColor }
    }

    /// The selected messages' text, one message per paragraph.
    var selectedText: String { selection.map(\.text).joined(separator: "\n\n") }

    @objc func copy(_ sender: Any?) {
        guard !selection.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(selectedText, forType: .string)
    }


    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }

    /// The message a context menu was opened on.
    private(set) var menuHit: HomeHit?

    /// Right-click or Control-click on a bubble: the tapback picker (only
    /// for a committed message with the owner's id, while online), then
    /// Copy. Actions the local owner refuses are not offered.
    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        return menu(at: point)
    }

    func menu(at point: CGPoint) -> NSMenu? {
        guard let controller, let hit = controller.hit(at: point) else { return nil }
        menuHit = hit
        let menu = NSMenu()
        if let target = controller.reactionTarget(for: hit, isOnline: reactionsEnabled) {
            let picker = NSMenuItem()
            picker.view = HomeTapbackPickerView(target: target) { [weak self] tapback in
                self?.react(tapback, to: target)
            }
            menu.addItem(picker)
            menu.addItem(.separator())
        }
        let copy = NSMenuItem(title: HomeStrings.copyMessage, action: #selector(copyMessage(_:)), keyEquivalent: "")
        copy.target = self
        menu.addItem(copy)
        // Only while a Cancel really stops something: an upload, or a send
        // that failed. A sent, unanswered message has no Cancel.
        if hit.isMine, controller.cancellableSend(hit.item) == true {
            let cancel = NSMenuItem(title: HomeStrings.cancelUpload, action: #selector(cancelUpload(_:)), keyEquivalent: "")
            cancel.target = self
            menu.addItem(cancel)
        }
        return menu
    }

    /// Sends a tapback through the controller's intents (`addReaction`).
    @discardableResult
    func react(_ tapback: Reaction.Tapback, to target: HomeReactionTarget) -> HomeIntent? {
        guard reactionsEnabled else { return nil }
        return controller?.react(tapback, to: target)
    }

    @objc func cancelUpload(_ sender: Any?) {
        guard let key = menuHit?.item else { return }
        _ = onCancelSend(key)
    }

    @objc func copyMessage(_ sender: Any?) {
        guard let text = menuHit?.text else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    /// The viewport or draft changed: rebuild the elements on the next read.
    func accessibilityChanged() {
        elements = []
    }

    /// The rows changed: VoiceOver re-reads the list.
    func rowsChanged() {
        elements = []
        NSAccessibility.post(element: self, notification: .layoutChanged)
    }

    override func accessibilityChildren() -> [Any]? {
        if elements.isEmpty, let controller { elements = controller.accessibilityItems().map(element) }
        return elements
    }

    private func element(_ item: HomeAXItem) -> NSAccessibilityElement {
        let e = NSAccessibilityElement()
        e.setAccessibilityParent(self)
        e.setAccessibilityRole(item.role == .textArea ? .textArea : .staticText)
        e.setAccessibilityLabel(item.label)
        e.setAccessibilityValue(item.value)
        e.setAccessibilityIdentifier(item.id)
        var actions: [NSAccessibilityCustomAction] = []
        if let target = controller?.reactionTarget(for: item, isOnline: reactionsEnabled) {
            actions = HomeReactionStyle().tapbacks.map { tapback in
                NSAccessibilityCustomAction(name: HomeReactionStyle().accessibilityName(tapback)) { [weak self] in
                    self?.react(tapback, to: target) != nil
                }
            }
        }
        if let action = videoAction(item) { actions.insert(action, at: 0) }
        if !actions.isEmpty { e.setAccessibilityCustomActions(actions) }
        let inWindow = convert(item.frame, to: nil)
        e.setAccessibilityFrame(window?.convertToScreen(inWindow) ?? inWindow)
        return e
    }
}

extension HomeRowHostView {
    /// Play or Pause on a video bubble's accessibility element.
    func videoAction(_ item: HomeAXItem) -> NSAccessibilityCustomAction? {
        guard let controller, let hit = controller.hit(at: CGPoint(x: item.frame.midX, y: item.frame.midY)),
              let key = item.item, hit.item == key,
              let state = controller.videoState(for: key, partIndex: hit.partIndex) else { return nil }
        let name = state == .playing ? HomeStrings.pauseVideo : HomeStrings.playVideo
        return NSAccessibilityCustomAction(name: name) { [weak self] in
            self?.onVideoClick(hit) ?? false
        }
    }
}

extension HomeRowHostView: NSMenuItemValidation {
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(copy(_:)) { return !selection.isEmpty }
        if item.action == #selector(copyMessage(_:)) { return menuHit != nil }
        if item.action == #selector(cancelUpload(_:)) { return menuHit != nil }
        return true
    }
}
