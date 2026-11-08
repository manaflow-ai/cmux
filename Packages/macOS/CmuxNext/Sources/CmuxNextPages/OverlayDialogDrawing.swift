public import AppKit
public import CmuxNextDesign
public import CmuxNextSettings
import CmuxNextWakeups

/// Draws every cmux dialog with the overlay page's React dialog (webviews/src/pages/overlay/dialog):
/// the shared center's `CmuxDialogOverlayHost` gets it at the composition root. Each shown dialog gets a warm overlay page view
/// (``OverlayPagePool``) that fills its region; the page draws the card and answers the person's
/// keys and clicks with the same rules as before (`CmuxDialogKeys`).
@MainActor
public final class OverlayDialogDrawing: CmuxDialogDrawing {
    let pool: OverlayPagePool<OverlayDialogProvider>
    private var views: [ObjectIdentifier: (container: OverlayDialogView, page: PageWebView)] = [:]

    /// Draws `center`'s dialogs from now on: its host becomes an overlay host with this drawing. Its pages
    /// run in `overlayProcess` (the app's one ``PageOverlayProcess``); nil gives each its own process.
    public init(drawing center: CmuxDialogCenter, overlayProcess: PageOverlayProcess? = nil) {
        // A dialog's page refuses page probes whatever it shows: a typed password, or a consent only the person answers.
        pool = OverlayPagePool(route: "/dialog", refusesProbes: true, overlayProcess: overlayProcess) { OverlayDialogProvider() }
        center.host = CmuxDialogOverlayHost(drawing: self)
    }

    /// Loads the view of the next dialog ahead (an idle moment after launch).
    public func prewarm() {
        pool.prewarm()
    }

    public func attach(_ dialog: CmuxDialogPresentation, in window: NSWindow?) -> NSView? {
        if let shown = views[ObjectIdentifier(dialog)] { return shown.container }
        guard let (page, provider) = pool.claim() else { return nil }
        let container = OverlayDialogView(page: page, activeLook: dialog.activeLook)
        container.setAccessibilityIdentifier(dialog.spec.identifier ?? "cmux.dialog")
        views[ObjectIdentifier(dialog)] = (container, page)
        dialog.renderer = provider
        provider.container = container
        provider.show(dialog)
        return container
    }

    public func focus(_ dialog: CmuxDialogPresentation) {
        guard let shown = views[ObjectIdentifier(dialog)] else { return }
        shown.page.focusPage()
        // Shown again (a tab switch): the card's own focus goes back to where a dialog opens.
        pool.provider(of: shown.page)?.resetFocus(dialog)
    }

    /// The page draws the card in its own turn, and a page claimed before the spare loaded draws later
    /// still: the host holds the dialog at its transparent first frame until the page says this dialog's
    /// card painted, or ``drawDeadline`` passes.
    public func whenDrawn(_ dialog: CmuxDialogPresentation, _ ready: @escaping () -> Void) {
        guard let shown = views[ObjectIdentifier(dialog)], let provider = pool.provider(of: shown.page) else { return ready() }
        let wait = OverlayDialogDrawWait(ready: ready)
        provider.whenCardPainted(dialog) { wait.finish() }
        wait.deadline.schedule(after: Self.drawDeadline) { @MainActor in wait.finish() }
    }

    /// The longest a dialog waits for its card: past it the host shows the dialog as it is.
    static let drawDeadline: Duration = .milliseconds(400)

    public func detach(_ dialog: CmuxDialogPresentation) {
        guard let (container, page) = views.removeValue(forKey: ObjectIdentifier(dialog)) else { return }
        // The card keeps what it shows through the overlay host's fade; it takes no more presses.
        pool.provider(of: page)?.retire()
        // Scrubbed before it waits for the next dialog: the page drops the card, and with it what the
        // person typed (a password), once the fade is over.
        container.releasePageWhenOffScreen { [pool] in
            // A private dialog's page keeps refusing probes as the spare: the next dialog's claim sets it again.
            pool.provider(of: page)?.show(nil)
            pool.release(page)
        }
        // The next dialog is drawn ahead, before it is asked.
        pool.prewarm()
    }
}

/// The dialog route's ops: the page subscribes to `cmux.overlay.dialog.state` (the dialog it draws,
/// or none) and calls `cmux.overlay.dialog.edit {id, values}`, `.press {id, button, values}`,
/// `.layout {id, card}` and `.painted {id}`.
@MainActor
final class OverlayDialogProvider: PageProvider, CmuxDialogRendering {
    private weak var dialog: CmuxDialogPresentation?
    /// The view showing the dialog: the card's glass follows the card the page lays out.
    weak var container: OverlayDialogView?
    private var listeners: [UUID: @MainActor (JSONValue) -> Void] = [:]
    /// Bumped by each focus move a key asks, so the page moves once per ask.
    private var focusSerial = 0
    private var focusBackward = false

    func show(_ dialog: CmuxDialogPresentation?) {
        self.dialog = dialog
        paintedDialog = nil
        focusSerial = 0
        valuesSerial = 0
        shows = 0
        publish()
    }

    /// The dialog ended: the page keeps drawing it while it fades, and its presses go nowhere.
    func retire() {
        // A dialog that ended before its card was drawn: its wait ends now.
        endPaintWaits()
        dialog = nil
        container = nil
    }

    /// Bumped by each show after the first, so the page puts its focus back to the opening one.
    private var shows = 0

    func resetFocus(_ dialog: CmuxDialogPresentation) {
        guard dialog === self.dialog else { return }
        shows += 1
        if shows > 1 { publish() }
    }

    /// Bumped by each value the host sets (automation's `setValue`), so the page takes the host's values,
    /// a secure field's too, over what the person typed.
    private var valuesSerial = 0

    /// Who waits for the shown dialog's card to paint (``OverlayDialogDrawing/whenDrawn(_:_:)``): the
    /// page says so (`painted`) a frame after it drew this dialog, not the document's first paint.
    private var cardPainted: [() -> Void] = []
    private var paintedDialog: ObjectIdentifier?

    func whenCardPainted(_ dialog: CmuxDialogPresentation, _ body: @escaping () -> Void) {
        guard dialog === self.dialog else { return body() }
        if paintedDialog == ObjectIdentifier(dialog) { body() } else { cardPainted.append(body) }
    }

    private func endPaintWaits() {
        let waiters = cardPainted
        cardPainted = []
        waiters.forEach { $0() }
    }

    func dialogValuesChanged(_ dialog: CmuxDialogPresentation) {
        guard dialog === self.dialog else { return }
        valuesSerial += 1
        publish()
    }

    func dialogMoveFocus(_ dialog: CmuxDialogPresentation, backward: Bool) {
        guard dialog === self.dialog else { return }
        // A key the window answered for the dialog (its panel lost key): the page takes the keyboard
        // back, so what the person types next reaches the field the focus moves to.
        container?.page.focusPage()
        focusSerial += 1
        focusBackward = backward
        publish()
    }

    func call(_ op: String, params: JSONValue, context: PageCallContext) async throws -> JSONValue {
        guard let dialog, params["id"]?.doubleValue == Double(dialog.id) else { return .null }
        switch op {
        // Answered as the person's: a dialog's page refuses page probes (the pool's `refusesProbes`), so no
        // `debug.page` call or script reaches it, while a click, a key or VoiceOver's press does.
        // An edit or press made against older values (an older `serial`: the page had not yet taken a value
        // automation set) leaves the host's values as they are, so a late edit never undoes that value.
        case "cmux.overlay.dialog.edit":
            dialog.edited(current(params) ? Self.values(params["values"]) : [:])
        case "cmux.overlay.dialog.press":
            guard let button = params["button"]?.stringValue else { throw PageError.invalidParams(op) }
            dialog.press(button, values: current(params) ? Self.values(params["values"]) : [:])
        case "cmux.overlay.dialog.layout":
            // CSS px from the page's top-left, in points at the page's zoom (the interface scale); the view
            // is flipped only when AppKit's bottom-left origin is not.
            guard let card = params["card"], let cssX = card["x"]?.doubleValue, let cssY = card["y"]?.doubleValue,
                  let cssW = card["w"]?.doubleValue, let cssH = card["h"]?.doubleValue else { throw PageError.invalidParams(op) }
            let zoom = max(container?.page.pageZoom ?? 1, 0.01)
            let (x, y, w, h) = (cssX * zoom, cssY * zoom, cssW * zoom, cssH * zoom)
            let height = dialog.view?.bounds.height ?? 0
            let rect = CGRect(x: x, y: (dialog.view?.isFlipped ?? false) ? y : height - y - h, width: w, height: h)
            dialog.cardRect = rect
            container?.placeCard(rect)
        case "cmux.overlay.dialog.painted":
            paintedDialog = ObjectIdentifier(dialog)
            endPaintWaits()
        default:
            throw PageError.unknownOp(op)
        }
        return .null
    }

    func subscribe(_ stream: String, filter: JSONValue, context: PageCallContext,
                   onEvent: @escaping @MainActor (JSONValue) -> Void) async throws -> PageSubscription {
        guard stream == "cmux.overlay.dialog.state" else { throw PageError.unknownOp(stream) }
        let token = UUID()
        listeners[token] = onEvent
        onEvent(state)
        return PageSubscription { [weak self] in self?.listeners[token] = nil }
    }

    private func publish() {
        let state = state
        for listener in listeners.values { listener(state) }
    }

    // MARK: Wire

    private var state: JSONValue {
        guard let dialog else { return ["dialog": .null] }
        var wire = Self.wire(dialog, focus: focusSerial == 0 ? .null : ["serial": .number(Double(focusSerial)),
                                                                       "backward": .bool(focusBackward)])
        if case .object(var object) = wire {
            object["shown"] = .number(Double(max(shows, 1)))
            object["valuesSerial"] = .number(Double(valuesSerial))
            wire = .object(object)
        }
        return ["dialog": wire]
    }

    static func wire(_ dialog: CmuxDialogPresentation, focus: JSONValue) -> JSONValue {
        let spec = dialog.spec
        var object: [String: JSONValue] = [
            "id": .number(Double(dialog.id)),
            "title": .string(spec.title),
            "lines": .array(spec.lines.map(JSONValue.string)),
            "fields": .array(spec.fields.map(wire)),
            "buttons": .array(spec.buttons.map { button in
                var row: [String: JSONValue] = ["id": .string(button.id), "title": .string(button.title),
                                                "role": .string(button.role.rawValue)]
                if let hint = dialog.hint(for: button) {
                    row["hint"] = .string(hint.glyph)
                    row["hintLabel"] = .string(hint.spokenName)
                }
                return .object(row)
            }),
            "keys": keys(spec),
            "layout": .string(spec.layout == .safeDefault ? "safeDefault" : "standard"),
            "values": .object(dialog.values.mapValues(wire)),
            "focus": focus,
        ]
        if let origin = spec.origin { object["from"] = .string(CmuxDialogStrings.from(origin)) }
        if let identifier = spec.identifier { object["identifier"] = .string(identifier) }
        if let icon = spec.icon, let png = iconPNG(icon) { object["icon"] = .string("data:image/png;base64," + png.base64EncodedString()) }
        return .object(object)
    }

    /// The buttons each key presses (`CmuxDialogKeys`): the page answers keys with exactly these.
    static func keys(_ spec: CmuxDialogSpec) -> JSONValue {
        var keys: [String: JSONValue] = [:]
        if let button = spec.defaultButton { keys["return"] = .string(button.id) }
        if let button = spec.cancelButton { keys["escape"] = .string(button.id) }
        var command: [String: JSONValue] = [:]
        for button in spec.buttons {
            guard let key = button.key, command[String(key)] == nil else { continue }
            command[String(key)] = .string(button.id)
        }
        keys["command"] = .object(command)
        return .object(keys)
    }

    static func wire(_ field: CmuxDialogField) -> JSONValue {
        switch field {
        case .text(let id, let label, _, let placeholder, let secure):
            var row: [String: JSONValue] = ["kind": "text", "id": .string(id), "secure": .bool(secure)]
            if let label { row["label"] = .string(label) }
            if let placeholder { row["placeholder"] = .string(placeholder) }
            return .object(row)
        case .choice(let id, let label, let options, _):
            var row: [String: JSONValue] = ["kind": "choice", "id": .string(id), "options": .array(options.map { option in
                ["label": .string(option.label), "value": .string(option.value), "enabled": .bool(option.isEnabled)]
            })]
            if let label { row["label"] = .string(label) }
            return .object(row)
        case .check(let id, let title, _):
            return ["kind": "check", "id": .string(id), "title": .string(title)]
        case .preview(let text):
            return ["kind": "preview", "text": .string(text)]
        }
    }

    static func wire(_ value: CmuxDialogValue) -> JSONValue {
        switch value {
        case .text(let text): .string(text)
        case .bool(let on): .bool(on)
        }
    }

    /// Whether the page made this call against the values the host last sent (its `serial`).
    private func current(_ params: JSONValue) -> Bool {
        (params["serial"]?.doubleValue ?? 0) == Double(valuesSerial)
    }

    static func values(_ json: JSONValue?) -> [String: CmuxDialogValue] {
        guard case .object(let members)? = json else { return [:] }
        return members.compactMapValues { value in
            switch value {
            case .string(let text): .text(text)
            case .bool(let on): .bool(on)
            default: nil
            }
        }
    }

    /// The spec's icon (PNG or TIFF) as PNG, which the page shows.
    private static func iconPNG(_ data: Data) -> Data? {
        if data.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return data }
        guard let image = NSImage(data: data), let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
        return bitmap.representation(using: .png, properties: [:])
    }
}

/// One shown dialog: the window's glass at the card's rect, under the transparent overlay page that
/// draws the card's contents. The page in the overlay panel cannot blur the window under it, so the
/// card's glass and shadow (``OverlayDialogCard``: the blur of what is behind the window, opaque under
/// Reduce Transparency) are native.
@MainActor
final class OverlayDialogView: NSView {
    let page: PageWebView
    /// The card's glass, under the page.
    let card: OverlayDialogCard

    init(page: PageWebView, activeLook: ActiveLookScope?) {
        self.page = page
        card = OverlayDialogCard(activeLook: activeLook)
        super.init(frame: .zero)
        card.isHidden = true
        card.translatesAutoresizingMaskIntoConstraints = true
        addSubview(card)
        page.removeFromSuperview()
        page.frame = bounds
        page.autoresizingMask = [.width, .height]
        addSubview(page)
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// The card's rect in this view, as the page laid it out: the glass goes there, in the same frame.
    func placeCard(_ rect: CGRect) {
        card.frame = rect
        card.isHidden = false
    }

    private var offScreen: (() -> Void)?

    /// Runs `release` once this view leaves its window (after the overlay host's fade), or now when it has none.
    func releasePageWhenOffScreen(_ release: @escaping () -> Void) {
        guard window != nil else { return release() }
        offScreen = release
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window == nil, let release = offScreen else { return }
        offScreen = nil
        page.removeFromSuperview()
        release()
    }
}

/// One dialog's wait for its card (``OverlayDialogDrawing/whenDrawn(_:_:)``): ends once, at the card
/// or the deadline, whichever comes first.
@MainActor
final class OverlayDialogDrawWait {
    let deadline = DemandTimer(owner: "OverlayDialogDrawing.draw")
    private var ready: (() -> Void)?

    init(ready: @escaping () -> Void) {
        self.ready = ready
    }

    func finish() {
        guard let ready else { return }
        self.ready = nil
        deadline.cancel()
        ready()
    }
}
