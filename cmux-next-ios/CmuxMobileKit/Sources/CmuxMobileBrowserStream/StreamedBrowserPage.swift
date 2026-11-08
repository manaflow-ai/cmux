#if os(iOS)
import AVFoundation
import SwiftUI
import UIKit

/// The live page of a streamed browser tab: the Mac's frames, laid out
/// between the status bar and the tab toolbar at this phone's size, with
/// touch, scroll, pinch and typing going back to the page.
public struct StreamedBrowserPage: View {
    let model: StreamedBrowserModel
    var insets: EdgeInsets
    var reportScroll: @MainActor (CGFloat) -> Void
    @State private var keyboard = false
    /// The keyboard rose because the page focused a field (it goes when the field does).
    @State private var raisedForField = false
    /// A JavaScript prompt's answer while its alert shows.
    @State private var promptText = ""
    @Environment(\.openURL) private var openURL

    /// What the page says when the Mac cannot stream browser tabs.
    public static let unavailableText = String(localized: "Browser tabs aren't available from this Mac.")

    public init(model: StreamedBrowserModel, insets: EdgeInsets, reportScroll: @escaping @MainActor (CGFloat) -> Void) {
        self.model = model
        self.insets = insets
        self.reportScroll = reportScroll
    }

    public var body: some View {
        ZStack(alignment: .bottomTrailing) {
            StreamSurface(model: model, keyboard: $keyboard, reportScroll: reportScroll)
                .accessibilityIdentifier("browser.stream")
            if model.phase == .unavailable {
                unavailable
            } else if case let .waiting(reason) = model.phase {
                if model.canReopen {
                    reopen(reason)
                } else {
                    status(reason)
                }
            } else if model.phase == .connecting {
                status("Opening on your Mac…")
            } else if let notice = model.notice {
                refusal(notice)
            }
            // Opens the keyboard; while it shows, the bar above it has Hide Keyboard
            // (this button would sit under the keyboard).
            if !keyboard {
                Button {
                    keyboard = true
                } label: {
                    Image(systemName: "keyboard")
                        .font(.system(size: 17, weight: .medium))
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: .circle)
                .padding(12)
                .accessibilityLabel(Text("Keyboard"))
                .accessibilityIdentifier("browser.keyboard")
            }
            if StreamedBrowserOverlay.enabled {
                StreamedBrowserOverlay(model: model)
                    // Bottom left, clear of the page's own top area (a page clock).
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                    .allowsHitTesting(false)
            }
        }
        .padding(.top, insets.top)
        .padding(.bottom, insets.bottom)
        .background(Color.black)
        .onAppear {
            model.setVisible(true)
            model.reconnect()
        }
        // The page focused a field: the keyboard rises (and goes again when the page
        // blurs a field it raised it for); the page lays out above it, and Chromium
        // keeps the focused field in view as its viewport shrinks.
        .onChange(of: model.field) { _, after in
            // A field gained focus (a new one too, after the person lowered the keyboard).
            if after != nil, !keyboard {
                keyboard = true
                raisedForField = true
            } else if after == nil, raisedForField {
                keyboard = false
                raisedForField = false
            }
        }
        .onChange(of: keyboard) { _, shown in if !shown { raisedForField = false } }
        .onDisappear { model.setVisible(false) }
        // The page's `<select>`: its options in a sheet. Swiping it away cancels; the page
        // closing the popup itself closes the sheet.
        .sheet(item: Binding(get: { model.selectMenu }, set: { [shown = model.selectMenu?.token] next in
            // Only the select this sheet showed: a late write never cancels a newer one.
            if next == nil, let shown { model.choose(.cancel, in: shown) }
        })) { open in
            StreamedSelectSheet(open: open) { model.choose($0, in: open.token) }
        }
        // A JavaScript alert, confirm, prompt or leave-page question as a system alert,
        // gone without an answer when the page closes it itself.
        .alert(model.dialog?.dialog.title ?? "", isPresented: Binding(get: { model.dialog != nil }, set: { _ in }),
               presenting: model.dialog) { open in
            if open.dialog.kind == .prompt {
                TextField(String(localized: "Answer"), text: $promptText)
                    .accessibilityIdentifier("browser.dialog.field")
            }
            // Answer only the question this alert displayed. The host may replace it
            // before SwiftUI redraws; a stale tap must leave the new question unanswered.
            if open.dialog.hasCancel {
                Button(String(localized: "Cancel"), role: .cancel) {
                    model.answerDialog(open.token, accept: false)
                }
            }
            Button(open.dialog.acceptTitle) {
                model.answerDialog(open.token, accept: true, text: promptText)
            }
        } message: { open in
            if !open.dialog.message.isEmpty { Text(open.dialog.message) }
        }
        .onChange(of: model.dialog?.token, initial: true) { _, _ in promptText = model.dialog?.dialog.defaultText ?? "" }
    }

    /// An honest state, with the page in Safari on this iPhone when it has a web address.
    private var unavailable: some View {
        VStack(spacing: 12) {
            Text(Self.unavailableText)
                .font(.callout)
                .multilineTextAlignment(.center)
            if let url = model.url, ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
                Button("Open in Safari") { openURL(url) }
                    .buttonStyle(.glass)
                    .accessibilityIdentifier("browser.openInSafari")
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("browser.unavailable")
    }

    /// The Mac stopped the page or another viewer took it: say so, with a
    /// way back (never a frozen frame).
    private func reopen(_ text: String) -> some View {
        VStack(spacing: 10) {
            Text(text)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Reopen") { model.reopen() }
                .buttonStyle(.glass)
                .accessibilityIdentifier("browser.reopen")
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// The Mac did not load an address: why, over the live page, until the next
    /// navigation or a tap.
    private func refusal(_ text: String) -> some View {
        Button { model.dismissNotice() } label: {
            Label(text, systemImage: "lock")
                .font(.footnote)
                .multilineTextAlignment(.leading)
                .padding(.horizontal, 14).padding(.vertical, 10)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 16))
        .padding(.horizontal, 16).padding(.top, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .accessibilityIdentifier("browser.refused")
        .accessibilityHint(Text("Dismisses this message"))
    }

    private func status(_ text: String) -> some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 14).padding(.vertical, 8)
            .glassEffect(.regular, in: .capsule)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The measurement overlay (DEBUG, or `-cmux-mobile-browser-meter`): frame rate,
/// bitrate, capture-to-decoded latency, decode time, and this phone's wall
/// clock in milliseconds to compare with a clock rendered by the Mac's page.
struct StreamedBrowserOverlay: View {
    let model: StreamedBrowserModel

    static var enabled: Bool {
        #if DEBUG
        // Public fixture captures show the product controls without the diagnostic meter.
        !ProcessInfo.processInfo.arguments.contains("-cmux-mobile-browser-events")
        #else
        // Release (Production, TestFlight): only for a measurement launch with
        // the explicit argument, never from a stored setting (Codex QA F13).
        ProcessInfo.processInfo.arguments.contains("-cmux-mobile-browser-meter")
        #endif
    }

    var body: some View {
        TimelineView(.animation) { context in
            let meter = model.meter
            VStack(alignment: .leading, spacing: 1) {
                Text("phone \(Self.clock(context.date))")
                Text("\(meter.fps) fps · \(meter.kbps) kbps · \(meter.width)×\(meter.height) · \(meter.carrier)")
                Text("latency \(meter.latencyMillis.map { String(format: "%.0f", $0) } ?? "–") ms · decode \(String(format: "%.1f", meter.decodeMillis)) ms")
            }
            .font(.system(size: 11, weight: .semibold, design: .monospaced))
            .foregroundStyle(.white)
            .padding(6)
            .background(.black.opacity(0.6), in: .rect(cornerRadius: 6))
            .padding(6)
            .accessibilityIdentifier("browser.meter")
        }
    }

    static func clock(_ date: Date) -> String {
        let ms = Int64(date.timeIntervalSince1970 * 1000)
        return String(format: "%02d:%02d.%03d", (ms / 60000) % 60, (ms / 1000) % 60, ms % 1000)
    }
}

/// The grid card: the last frame, else a globe (an iPhone for a simulator tab).
public struct StreamedBrowserCard: View {
    let model: StreamedBrowserModel
    let placeholder: String
    /// A simulator's frame is shown whole and centred; a page's fills the width from the top.
    let fit: Bool

    public init(model: StreamedBrowserModel, placeholder: String = "globe", fit: Bool = false) {
        self.model = model
        self.placeholder = placeholder
        self.fit = fit
    }

    public var body: some View {
        ZStack(alignment: .top) {
            Color(uiColor: .systemBackground)
            if fit, let image = model.snapshot?.image {
                Color.black
                Image(decorative: image, scale: 1).resizable().interpolation(.medium).scaledToFit()
            } else if let image = model.snapshot?.image {
                GeometryReader { geo in
                    Image(decorative: image, scale: 1).resizable().interpolation(.medium)
                        .frame(width: geo.size.width,
                               height: geo.size.width * CGFloat(image.height) / CGFloat(max(1, image.width)))
                }
            } else {
                Image(systemName: placeholder)
                    .font(.system(size: 72, weight: .light))
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

struct StreamSurface: UIViewRepresentable {
    let model: StreamedBrowserModel
    @Binding var keyboard: Bool
    var reportScroll: @MainActor (CGFloat) -> Void

    func makeUIView(context: Context) -> StreamView {
        let view = StreamView(model: model)
        view.keyboardChanged = { shown in
            if keyboard != shown { keyboard = shown }
        }
        return view
    }

    func updateUIView(_ view: StreamView, context: Context) {
        view.reportScroll = reportScroll
        view.fieldChanged()
        if keyboard, !view.isFirstResponder {
            // Not in a window yet, or focus held elsewhere: the button comes back.
            if !view.becomeFirstResponder() {
                DispatchQueue.main.async { keyboard = false }
            }
        } else if !keyboard, view.isFirstResponder {
            view.resignFirstResponder()
        }
    }
}

/// Shows the decoder's layer and turns touches into rb input (CSS pixels).
final class StreamView: UIView, UIKeyInput, UIContextMenuInteractionDelegate {
    let model: StreamedBrowserModel
    var reportScroll: (@MainActor (CGFloat) -> Void)?
    var keyboardChanged: ((Bool) -> Void)?
    private let video: AVSampleBufferDisplayLayer
    private var lastPan: CGPoint = .zero
    private var momentum: CADisplayLink?
    private var velocity: CGPoint = .zero
    private var momentumAt: CGPoint = .zero
    private var lastStep: CFTimeInterval = 0
    /// How much of the view the software keyboard covers: the page lays out above it,
    /// so the field being typed in stays in sight (as Safari's page shrinks).
    private var covered: CGFloat = 0
    /// The software keyboard's frame on the screen, when it shows: `covered` is
    /// worked out again at each layout (rotation, split view), not only per notification.
    private var keyboardOnScreen: CGRect?
    private lazy var keyBar = StreamKeyBar(target: self)
    /// Find in page: the system find bar; the Mac's browser finds (`rb.find`).
    private lazy var finder = StreamedBrowserFindController(model: model)

    init(model: StreamedBrowserModel) {
        self.model = model
        video = model.decoder.layer
        super.init(frame: .zero)
        backgroundColor = .black
        video.removeFromSuperlayer()
        layer.addSublayer(video)
        let tap = UITapGestureRecognizer(target: self, action: #selector(tapped(_:)))
        let pan = UIPanGestureRecognizer(target: self, action: #selector(panned(_:)))
        pan.maximumNumberOfTouches = 1
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(pinched(_:)))
        addGestureRecognizer(tap)
        addGestureRecognizer(pan)
        addGestureRecognizer(pinch)
        // A long press shows the page's own menu for that spot (links, images, text), as
        // a secondary click does on the Mac: Safari's long press, with the Mac's rows.
        addInteraction(UIContextMenuInteraction(delegate: self))
        // On the page itself: the find bar's interaction needs a view that can take the keyboard.
        finder.install(in: self)
        finder.pageHasFocus = { [weak self] in self?.isFirstResponder ?? false }
        finder.ended = { [weak self] restoreFocus in
            guard let self else { return }
            if restoreFocus { _ = becomeFirstResponder() } else if !isFirstResponder { cover(nil) }
        }
        isAccessibilityElement = true
        accessibilityTraits = .allowsDirectInteraction
        accessibilityIdentifier = "browser.page"
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardFrame(_:)),
                                               name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardHidden(_:)),
                                               name: UIResponder.keyboardWillHideNotification, object: nil)
    }

    /// The visible page: the view less what the keyboard covers.
    private var pageSize: CGSize { CGSize(width: bounds.width, height: max(64, bounds.height - covered)) }

    @objc private func keyboardFrame(_ note: Notification) {
        // The page's own keyboard, or the find bar's: the page lays out above either, so the
        // match the Mac scrolls to stays in sight.
        guard isFirstResponder || finder.isActive,
              let end = (note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue else { return }
        keyboardOnScreen = end
        setNeedsLayout()
    }

    @objc private func keyboardHidden(_ note: Notification) { cover(nil) }

    private func cover(_ keyboard: CGRect?) {
        keyboardOnScreen = keyboard
        setNeedsLayout()
    }

    /// How much of this view the keyboard covers now.
    private func coveredNow() -> CGFloat {
        guard let window, let keyboard = keyboardOnScreen else { return 0 }
        return StreamedBrowserKey.covered(page: convert(bounds, to: window),
                                          keyboard: window.convert(keyboard, from: window.screen.coordinateSpace))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layoutSubviews() {
        super.layoutSubviews()
        covered = coveredNow()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        video.frame = CGRect(origin: .zero, size: pageSize)
        CATransaction.commit()
        model.layout(points: pageSize, screenScale: Double(window?.screen.scale ?? traitCollection.displayScale))
    }

    private func css(_ point: CGPoint) -> (x: Double, y: Double) { model.css(point, in: pageSize) }

    @objc private func tapped(_ gesture: UITapGestureRecognizer) {
        stopMomentum()
        let (x, y) = css(gesture.location(in: self))
        model.input(model.wire.pointer("move", x: x, y: y, buttons: 0), mustDeliver: false)
        model.input(model.wire.pointer("down", x: x, y: y, buttons: 1))
        model.input(model.wire.pointer("up", x: x, y: y, buttons: 0))
    }

    @objc private func panned(_ gesture: UIPanGestureRecognizer) {
        let at = css(gesture.location(in: self))
        let translation = gesture.translation(in: self)
        switch gesture.state {
        case .began:
            stopMomentum()
            lastPan = translation
            model.input(model.wire.wheel(x: at.x, y: at.y, dx: 0, dy: 0, phase: "began", momentum: "none"))
        case .changed:
            let dx = translation.x - lastPan.x
            let dy = translation.y - lastPan.y
            lastPan = translation
            model.input(model.wire.wheel(x: at.x, y: at.y, dx: dx, dy: dy, phase: "changed", momentum: "none"), mustDeliver: false)
            reportScroll?(dy)
        case .ended, .cancelled, .failed:
            model.input(model.wire.wheel(x: at.x, y: at.y, dx: 0, dy: 0, phase: "ended", momentum: "none"))
            let v = gesture.velocity(in: self)
            if gesture.state == .ended, hypot(v.x, v.y) > 200 { startMomentum(velocity: v, at: CGPoint(x: at.x, y: at.y)) }
        default:
            break
        }
    }

    /// The fling after a pan, as macOS momentum wheel events (decay 0.95 per 1/60 s).
    private func startMomentum(velocity: CGPoint, at: CGPoint) {
        self.velocity = velocity
        momentumAt = at
        lastStep = CACurrentMediaTime()
        model.input(model.wire.wheel(x: at.x, y: at.y, dx: 0, dy: 0, phase: "none", momentum: "began"))
        let link = CADisplayLink(target: self, selector: #selector(stepMomentum(_:)))
        link.add(to: .main, forMode: .common)
        momentum = link
    }

    @objc private func stepMomentum(_ link: CADisplayLink) {
        let now = link.timestamp
        let dt = max(0, min(0.05, now - lastStep))
        lastStep = now
        let decay = pow(0.95, dt * 60)
        velocity = CGPoint(x: velocity.x * decay, y: velocity.y * decay)
        if hypot(velocity.x, velocity.y) < 20 {
            stopMomentum()
            return
        }
        model.input(model.wire.wheel(x: momentumAt.x, y: momentumAt.y, dx: velocity.x * dt, dy: velocity.y * dt,
                                     phase: "none", momentum: "changed"), mustDeliver: false)
    }

    private func stopMomentum() {
        guard let link = momentum else { return }
        link.invalidate()
        momentum = nil
        model.input(model.wire.wheel(x: momentumAt.x, y: momentumAt.y, dx: 0, dy: 0, phase: "none", momentum: "ended"))
    }

    @objc private func pinched(_ gesture: UIPinchGestureRecognizer) {
        let (x, y) = css(gesture.location(in: self))
        let phase: String = switch gesture.state {
        case .began: "began"
        case .changed: "changed"
        case .ended: "ended"
        default: "cancelled"
        }
        model.input(model.wire.pinch(phase: phase, scale: gesture.scale, x: x, y: y), mustDeliver: phase != "changed")
    }

    // MARK: Page menu (long press)

    /// Where the long press is, in this view.
    private var menuPoint: CGPoint = .zero
    /// The page's menu for the menu on screen (nil until the menu shows).
    private var menuWait: StreamMenuWait?
    /// An empty spot at the press: the menu opens from it instead of lifting the whole page.
    private lazy var menuAnchor: UIView = {
        let anchor = UIView(frame: CGRect(x: 0, y: 0, width: 2, height: 2))
        anchor.isUserInteractionEnabled = false
        anchor.backgroundColor = .clear
        addSubview(anchor)
        return anchor
    }()

    func contextMenuInteraction(_ interaction: UIContextMenuInteraction,
                                configurationForMenuAtLocation location: CGPoint) -> UIContextMenuConfiguration? {
        guard model.phase == .live else { return nil }
        menuPoint = location
        let (x, y) = css(location)
        let wait = StreamMenuWait()
        menuWait = wait
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            UIMenu(children: [UIDeferredMenuElement.uncached { completion in
                // UIKit asks for the rows on the main thread, only once the menu shows: the
                // page is asked then (a press that turns into a scroll asks nothing), and the
                // menu fills in when its rows arrive.
                MainActor.assumeIsolated {
                    guard let self else { return completion([]) }
                    if !wait.asked {
                        wait.asked = true
                        self.stopMomentum()
                        self.model.requestContextMenu(x: x, y: y) { open in wait.arrived(open) }
                    }
                    wait.whenArrived { [weak self] open in completion(self?.menuElements(open) ?? []) }
                }
            }])
        }
    }

    func contextMenuInteraction(_ interaction: UIContextMenuInteraction,
                                configuration: UIContextMenuConfiguration,
                                highlightPreviewForItemWithIdentifier identifier: any NSCopying) -> UITargetedPreview? {
        pressPreview()
    }

    func contextMenuInteraction(_ interaction: UIContextMenuInteraction,
                                configuration: UIContextMenuConfiguration,
                                dismissalPreviewForItemWithIdentifier identifier: any NSCopying) -> UITargetedPreview? {
        pressPreview()
    }

    /// The menu closed: a menu nobody chose from is cancelled on the page (its choice, when
    /// there was one, has already gone; `choose` sends each menu's answer once).
    func contextMenuInteraction(_ interaction: UIContextMenuInteraction, willEndFor configuration: UIContextMenuConfiguration,
                                animator: (any UIContextMenuInteractionAnimating)?) {
        guard let wait = menuWait else { return }
        menuWait = nil
        let model = model
        // This press's menu only (never a later press's), cancelled when nothing was picked:
        // `choose` answers each menu once, so a pick sent first wins, and a menu still on its
        // way is cancelled when it comes.
        let abandon: @MainActor @Sendable () -> Void = {
            wait.whenArrived { open in if let open { model.choose(.cancel, in: open.token) } }
        }
        // UIKit runs the chosen row's handler as the menu closes: the cancel goes after it.
        guard let animator else {
            Task { @MainActor in abandon() }
            return
        }
        animator.addCompletion { Task { @MainActor in abandon() } }
    }

    private func pressPreview() -> UITargetedPreview {
        menuAnchor.center = menuPoint
        let parameters = UIPreviewParameters()
        parameters.backgroundColor = .clear
        parameters.visiblePath = UIBezierPath(rect: menuAnchor.bounds)
        return UITargetedPreview(view: menuAnchor, parameters: parameters)
    }

    /// The page's rows as a system menu: separators as sections, submenus nested, checked
    /// rows marked. A page that sent no menu (it handles the press itself) says so.
    private func menuElements(_ open: StreamedBrowserModel.OpenMenu?) -> [UIMenuElement] {
        let rows = open?.menu.phoneItems ?? []
        guard let open, !rows.isEmpty else {
            return [UIAction(title: String(localized: "No actions for this spot"), attributes: .disabled) { _ in }]
        }
        return Self.sections(rows) { [weak self] id in self?.model.choose(.command(id), in: open.token) }
    }

    static func sections(_ rows: [RemoteBrowserMenuItem], choose: @escaping @MainActor (Int64) -> Void) -> [UIMenuElement] {
        var sections: [[UIMenuElement]] = [[]]
        for row in rows {
            if row.type == "separator" {
                sections.append([])
                continue
            }
            if row.type == "submenu" {
                sections[sections.count - 1].append(UIMenu(title: row.label, children: Self.sections(row.items, choose: choose)))
                continue
            }
            let id = row.id
            let action = UIAction(title: row.label, identifier: UIAction.Identifier("browser.menu.\(id)"),
                                  attributes: row.enabled ? [] : .disabled, state: row.checked ? .on : .off) { _ in choose(id) }
            sections[sections.count - 1].append(action)
        }
        let filled = sections.filter { !$0.isEmpty }
        if filled.count == 1 { return filled[0] }
        return filled.map { UIMenu(title: "", options: .displayInline, children: $0) }
    }

    // MARK: Keyboard

    override var canBecomeFirstResponder: Bool { true }

    /// Hardware keys sent to the page, by press: their key-up goes on release (so a
    /// held arrow repeats on the Mac), and UIKit never sees half of them.
    private var heldKeys: [ObjectIdentifier: StreamedHardwareKey] = [:]

    private static func modifiers(_ flags: UIKeyModifierFlags) -> RemoteBrowserWire.Modifiers {
        var modifiers: RemoteBrowserWire.Modifiers = []
        if flags.contains(.shift) { modifiers.insert(.shift) }
        if flags.contains(.control) { modifiers.insert(.control) }
        if flags.contains(.alternate) { modifiers.insert(.option) }
        if flags.contains(.command) { modifiers.insert(.command) }
        return modifiers
    }

    /// A hardware keyboard's arrows, Escape, Home/End and shortcuts go to the page
    /// directly (the text path never sees them); everything else types as usual.
    /// Command-V stays the edit menu's Paste (`paste(_:)`: the phone's clipboard).
    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var rest = Set<UIPress>()
        for press in presses {
            guard let key = press.key else { rest.insert(press); continue }
            let modifiers = Self.modifiers(key.modifierFlags)
            if modifiers == .command, key.keyCode == .keyboardV {
                rest.insert(press)
            } else if modifiers == .command, key.keyCode == .keyboardF {
                // The Mac's Cmd-F: this phone's find bar over the page (never the Mac's own).
                finder.present()
            } else if modifiers == .command || modifiers == [.command, .shift], key.keyCode == .keyboardG {
                // Find Next / Find Previous.
                finder.step(forward: modifiers == .command)
            } else if let hardware = StreamedHardwareKey(usage: key.keyCode.rawValue,
                                                         characters: key.charactersIgnoringModifiers,
                                                         modifiers: modifiers) {
                heldKeys[ObjectIdentifier(press)] = hardware
                model.input(hardware.events(model.wire)[0])
            } else {
                rest.insert(press)
            }
        }
        if !rest.isEmpty { super.pressesBegan(rest, with: event) }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        super.pressesEnded(releaseHeld(presses), with: event)
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        super.pressesCancelled(releaseHeld(presses), with: event)
    }

    /// Sends the key-up of each held key and returns the presses that were not ours.
    private func releaseHeld(_ presses: Set<UIPress>) -> Set<UIPress> {
        var rest = Set<UIPress>()
        for press in presses {
            if let hardware = heldKeys.removeValue(forKey: ObjectIdentifier(press)) {
                model.input(hardware.events(model.wire)[1])
            } else {
                rest.insert(press)
            }
        }
        return rest
    }


    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became { keyboardChanged?(true) }
        return became
    }

    /// Dismissing the keyboard only hides it: the page's focus on the Mac stays.
    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned {
            keyboardChanged?(false)
            cover(nil)
        }
        return resigned
    }

    /// The keys iOS lacks (Escape, Tab, arrows, shortcuts), Paste and Done.
    override var inputAccessoryView: UIView? { keyBar }

    var hasText: Bool { true }
    var autocorrectionType: UITextAutocorrectionType { get { .no } set {} }
    var autocapitalizationType: UITextAutocapitalizationType { get { .none } set {} }
    var spellCheckingType: UITextSpellCheckingType { get { .no } set {} }
    var smartQuotesType: UITextSmartQuotesType { get { .no } set {} }
    var smartDashesType: UITextSmartDashesType { get { .no } set {} }
    var keyboardType: UIKeyboardType { get { .default } set {} }
    /// A password field on the page: iOS neither suggests nor learns what is typed.
    var isSecureTextEntry: Bool { get { model.field?.inputType == "password" } set {} }
    private var secure = false

    /// The focused field changed: the keyboard's traits follow it (secure entry).
    func fieldChanged() {
        let now = isSecureTextEntry
        guard now != secure else { return }
        secure = now
        if isFirstResponder { reloadInputViews() }
    }

    func insertText(_ text: String) {
        for event in StreamedBrowserKey.typed(text, wire: model.wire) { model.input(event) }
    }

    func deleteBackward() {
        model.input(model.wire.key("Backspace", key: "Backspace", down: true))
        model.input(model.wire.key("Backspace", key: "Backspace", down: false))
    }

    func send(_ key: StreamedBrowserKey) {
        for event in key.events(model.wire) { model.input(event) }
    }

    /// The phone's clipboard text into the page (the Mac's own Paste would paste the
    /// Mac's clipboard). iOS asks the person before an app reads it.
    func pastePhoneClipboard() {
        guard let text = UIPasteboard.general.string, !text.isEmpty else { return }
        model.input(model.wire.commit(text))
    }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        action == #selector(paste(_:)) ? UIPasteboard.general.hasStrings : super.canPerformAction(action, withSender: sender)
    }

    override func paste(_ sender: Any?) { pastePhoneClipboard() }

    // The standard find actions (a key command or menu that sends them): the find bar.
    override func find(_ sender: Any?) { finder.present() }
    override func findNext(_ sender: Any?) { finder.step(forward: true) }
    override func findPrevious(_ sender: Any?) { finder.step(forward: false) }

    func done() { _ = resignFirstResponder() }
}

/// The bar above the keyboard of a streamed page.
final class StreamKeyBar: UIInputView {
    init(target: StreamView) {
        super.init(frame: CGRect(x: 0, y: 0, width: 0, height: 46), inputViewStyle: .keyboard)
        allowsSelfSizing = true
        let scroll = UIScrollView()
        scroll.showsHorizontalScrollIndicator = false
        let stack = UIStackView()
        stack.axis = .horizontal
        stack.spacing = 2
        func button(_ symbol: String, _ title: String, id: String, _ action: @escaping () -> Void) -> UIButton {
            var config = UIButton.Configuration.plain()
            config.image = UIImage(systemName: symbol)
            config.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 10, bottom: 8, trailing: 10)
            let button = UIButton(configuration: config, primaryAction: UIAction { _ in action() })
            button.accessibilityLabel = title
            button.accessibilityIdentifier = "browser.key.\(id)"
            return button
        }
        for key in StreamedBrowserKey.allCases {
            stack.addArrangedSubview(button(key.symbol, key.title, id: key.rawValue) { [weak target] in target?.send(key) })
        }
        stack.addArrangedSubview(button("doc.on.clipboard", String(localized: "Paste"), id: "paste") { [weak target] in
            target?.pastePhoneClipboard()
        })
        let done = button("keyboard.chevron.compact.down", String(localized: "Hide Keyboard"), id: "done") { [weak target] in
            target?.done()
        }
        for view in [scroll, stack, done] { view.translatesAutoresizingMaskIntoConstraints = false }
        scroll.addSubview(stack)
        addSubview(scroll)
        addSubview(done)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor, constant: 4),
            scroll.trailingAnchor.constraint(equalTo: done.leadingAnchor),
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            stack.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor),
            done.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor, constant: -4),
            done.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: 46),
        ])
        accessibilityIdentifier = "browser.keys"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
}
#endif

#if os(iOS)
/// The page's menu for one long press: it may arrive before or after the system asks
/// for the menu's rows.
@MainActor
final class StreamMenuWait {
    /// The page was asked for its menu (the menu showed).
    var asked = false
    private var result: StreamedBrowserModel.OpenMenu??
    private var waiting: [(StreamedBrowserModel.OpenMenu?) -> Void] = []

    func arrived(_ open: StreamedBrowserModel.OpenMenu?) {
        result = .some(open)
        let waiting = waiting
        self.waiting = []
        for waiter in waiting { waiter(open) }
    }

    func whenArrived(_ then: @escaping (StreamedBrowserModel.OpenMenu?) -> Void) {
        if let result { then(result) } else { waiting.append(then) }
    }
}

/// A `<select>`'s options, as Safari lists them: a tap picks one (a multiple select
/// toggles rows and Done sends them); Cancel or a swipe leaves the page as it was.
struct StreamedSelectSheet: View {
    let open: StreamedBrowserModel.OpenMenu
    let choose: (RemoteBrowserMenuChoice) -> Void
    @State private var picked: Set<Int> = []

    init(open: StreamedBrowserModel.OpenMenu, choose: @escaping (RemoteBrowserMenuChoice) -> Void) {
        self.open = open
        self.choose = choose
        let checked = open.menu.items.indices.filter { open.menu.items[$0].checked }
        _picked = State(initialValue: Set(open.menu.multiple ? checked : open.menu.selected.map { [$0] } ?? []))
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(Array(open.menu.items.enumerated()), id: \.offset) { index, item in
                    row(index, item)
                }
            }
            .listStyle(.insetGrouped)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "Cancel")) { choose(.cancel) }
                        .accessibilityIdentifier("browser.select.cancel")
                }
                if open.menu.multiple {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(String(localized: "Done")) { choose(.indices(picked.sorted())) }
                            .accessibilityIdentifier("browser.select.done")
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .accessibilityIdentifier("browser.select")
    }

    @ViewBuilder
    private func row(_ index: Int, _ item: RemoteBrowserMenuItem) -> some View {
        switch item.type {
        case "separator":
            EmptyView()
        case "group":
            Text(item.label)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
        default:
            Button {
                if open.menu.multiple {
                    if picked.contains(index) { picked.remove(index) } else { picked.insert(index) }
                } else {
                    choose(.indices([index]))
                }
            } label: {
                HStack {
                    Text(item.label).foregroundStyle(item.enabled ? Color.primary : Color.secondary)
                    Spacer()
                    if picked.contains(index) {
                        Image(systemName: "checkmark").foregroundStyle(.tint)
                    }
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .disabled(!item.enabled)
            .accessibilityAddTraits(picked.contains(index) ? .isSelected : [])
            .accessibilityIdentifier("browser.select.option.\(index)")
        }
    }
}
#endif
