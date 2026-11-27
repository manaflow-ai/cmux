import AppKit
import CmuxHomeCore

/// The Chief's Cloud flow rows, both stored as `MessagePart.work` (CmuxChief):
///
/// - The provisioning row: one updating line for every `cmux vm new` / `vm wait` call
///   of a turn (`WorkRef.session` starts with `provisionPrefix`, the owner's
///   `ChiefCloudProvisioning.sessionPrefix`): "Creating cloud machine… 40s" with a
///   spinner, then "Cloud machine ready · brave-otter" or "Couldn't create cloud machine".
///   Full width, like a tool line, never folded into a run of tool calls.
/// - The result card: a work part whose `host` is the machine and whose `session` is the
///   machine workspace (`ws_…`, from a `cmux-result` block): title, subtitle, the agent's
///   state, an "Open Workspace" button (`ChatIntents.openCloudWorkspace`, the app's
///   `cmux vm workspace open` path), an "Open Desktop" button (`ChatIntents.openCloudDesktop`,
///   the app's `cmux vm desktop` path) and a quiet "Stop Machine" (`ChatIntents.stopCloudMachine`:
///   the click asks the Chief, whose `cmux vm pause` shows an approval card, so stopping is
///   still confirmed where every other state change is). A `waiting` card (the agent waits for
///   the user's sign-in, the Chief's `needs_sign_in`) shows an orange dot and "Needs sign-in".
///
/// References (cmux-design-references): topics/status-and-progress.md and
/// apps/codex/web/tools-running-progress.png (one live progress line with elapsed time
/// instead of a stream of command bubbles), topics/first-run.md (end on a concrete next
/// step with its state and one action).
enum ChiefCloudRows {
    static let provisionKind = "cmux.chief.cloud.provision"
    static let resultKind = "cmux.chief.cloud.result"
    /// CmuxChief's `ChiefCloudProvisioning.sessionPrefix` (MessagesLab does not link CmuxChief).
    static let provisionPrefix = "chief.provision:"

    static func isProvisioning(_ work: WorkRef) -> Bool { work.session.hasPrefix(provisionPrefix) }
    static func isResult(_ work: WorkRef) -> Bool { work.host != nil && !isProvisioning(work) }
    /// A work part that is one of these rows, not a tool call.
    static func handles(_ work: WorkRef) -> Bool { isProvisioning(work) || isResult(work) }

    /// `waiting`: a result card whose agent waits for the user (sign-in); a provisioning row never waits.
    enum State: String, Codable, Hashable { case running, waiting, done, failed }

    static func state(_ status: WorkRef.Status) -> State {
        switch status {
        case .running, .waiting: return .running
        case .done: return .done
        case .failed: return .failed
        }
    }

    /// A result card's state: the owner stores `needs_sign_in` as `.waiting`.
    static func resultState(_ status: WorkRef.Status) -> State {
        status == .waiting ? .waiting : state(status)
    }

    struct Provision: Codable, Hashable {
        var id: String
        var state: State
        /// The machine id (`host`): the tooltip once a name shows.
        var machine: String?
        /// The machine's name ("chief-dogfood-1", the owner's preview while the row has not failed).
        var name: String?
        /// The row's message time (seconds since 1970): elapsed time counts from it.
        var startedAt: Double
        /// A failure's output (tooltip).
        var detail: String?
    }

    struct Result: Codable, Hashable {
        var title: String
        var subtitle: String?
        var machine: String
        var workspace: String
        var state: State
        /// The machine's name from the turn's provisioning row ("chief-dogfood-1"); the card shows it,
        /// the raw id (`machine`) stays in the tooltip. Nil keeps older payloads' bytes.
        var name: String?

        /// The machine as the card shows it.
        var shownMachine: String { name ?? machine }
    }

    /// The row of a work part shown as one of these rows; nil for a tool call.
    static func part(_ work: WorkRef, createdAt: Date, machineName: String? = nil) -> CustomPart? {
        if isProvisioning(work) {
            return ChiefRows.part(kind: provisionKind, Provision(id: work.session, state: state(work.status), machine: work.host,
                                                                 name: work.status == .failed ? nil : work.preview,
                                                                 startedAt: createdAt.timeIntervalSince1970.rounded(),
                                                                 detail: work.status == .failed ? work.preview : nil))
        }
        guard let machine = work.host else { return nil }
        return ChiefRows.part(kind: resultKind, Result(title: work.title, subtitle: work.preview, machine: machine,
                                                       workspace: work.session, state: resultState(work.status), name: machineName))
    }

    /// "40s", "1m 5s": the system's short duration.
    static func elapsed(_ seconds: TimeInterval) -> String {
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .abbreviated
        formatter.allowedUnits = seconds >= 3600 ? [.hour, .minute] : [.minute, .second]
        formatter.zeroFormattingBehavior = .dropLeading
        return formatter.string(from: max(0, seconds.rounded(.down))) ?? ""
    }

    static func provisionText(_ p: Provision, now: Date) -> String {
        switch p.state {
        case .running, .waiting: return CmuxStrings.cloudCreating(elapsed(now.timeIntervalSince1970 - p.startedAt))
        case .done: return [CmuxStrings.cloudReady, p.name ?? p.machine].compactMap { $0 }.joined(separator: " · ")
        case .failed: return CmuxStrings.cloudFailed
        }
    }

    static func statusText(_ s: State) -> String {
        switch s {
        case .running: return CmuxStrings.cloudStatusWorking
        case .waiting: return CmuxStrings.cloudStatusNeedsSignIn
        case .done: return CmuxStrings.cloudStatusReady
        case .failed: return CmuxStrings.cloudStatusFailed
        }
    }
}

// MARK: Provisioning row

final class ChiefProvisionRowProvider: TranscriptCustomRowProvider {
    static let shared = ChiefProvisionRowProvider()
    static let height: CGFloat = 22

    let kind = ChiefCloudRows.provisionKind
    var measuresOffMain: Bool { true }
    func layout(for part: CustomPart) -> CustomRowLayout { .fullWidth }
    func measure(_ part: CustomPart, maxWidth: CGFloat) -> CGSize { CGSize(width: maxWidth, height: Self.height) }
    func estimate(_ part: CustomPart, maxWidth: CGFloat) -> CGSize { measure(part, maxWidth: maxWidth) }
    func makeView() -> CustomRowPlatformView { ChiefProvisionRowView() }

    func configure(_ view: CustomRowPlatformView, part: CustomPart, context: CustomRowContext) {
        guard let v = view as? ChiefProvisionRowView, let p = part.decode(ChiefCloudRows.Provision.self) else { return }
        v.show(p)
    }

    func prepareForReuse(_ view: CustomRowPlatformView) { (view as? ChiefProvisionRowView)?.reset() }

    func plainText(_ part: CustomPart) -> String? {
        part.decode(ChiefCloudRows.Provision.self).map { ChiefCloudRows.provisionText($0, now: Date()) }
    }
}

/// The line: cloud glyph, text, and a spinner, check or exclamation mark. While it
/// runs, a one-second timer redraws the elapsed time (a clock label, not a wait).
final class ChiefProvisionRowView: NSView {
    private var row: ChiefCloudRows.Provision?
    private let spinner = NSProgressIndicator()
    private var ticker: Timer?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        addSubview(spinner)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityIdentifier("ChiefProvisionRow")
    }
    required init?(coder: NSCoder) { nil }
    override var isFlipped: Bool { true }

    func reset() {
        row = nil
        stopTicker()
        spinner.stopAnimation(nil)
        toolTip = nil
    }

    func show(_ p: ChiefCloudRows.Provision) {
        row = p
        // A failure's output, else the machine id behind the name the line shows.
        toolTip = p.detail ?? (p.name != nil ? p.machine : nil)
        updateTicker()
        refresh()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateTicker()
    }

    private func updateTicker() {
        guard row?.state == .running || row?.state == .waiting, window != nil else {
            stopTicker()
            spinner.stopAnimation(nil)
            return
        }
        spinner.startAnimation(nil)
        guard ticker == nil else { return }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        timer.tolerance = 0.2
        RunLoop.main.add(timer, forMode: .common)
        ticker = timer
    }

    private func stopTicker() {
        ticker?.invalidate()
        ticker = nil
    }

    private func refresh() {
        guard let row else { return }
        let text = ChiefCloudRows.provisionText(row, now: Date())
        setAccessibilityLabel(text)
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        let width = min(bounds.width, ChiefToolRowView.maxLineWidth)
        spinner.frame = NSRect(x: width - 20, y: (bounds.height - 16) / 2, width: 16, height: 16)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let row else { return }
        let width = min(bounds.width, ChiefToolRowView.maxLineWidth)
        let secondary = Fixture.secondaryText
        let config = NSImage.SymbolConfiguration(pointSize: 12, weight: .regular).applying(NSImage.SymbolConfiguration(paletteColors: [secondary]))
        if let img = NSImage(systemSymbolName: "cloud", accessibilityDescription: nil)?.withSymbolConfiguration(config) {
            let s = img.size
            img.draw(in: NSRect(x: ChiefToolRowView.glyphX, y: ((bounds.height - s.height) / 2).rounded(), width: s.width, height: s.height),
                     from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        let label = NSAttributedString(string: ChiefCloudRows.provisionText(row, now: Date()), attributes: [
            .font: HomeFonts.system(ofSize: 12, weight: row.state == .running || row.state == .waiting ? .regular : .medium),
            .foregroundColor: row.state == .failed ? NSColor.systemRed : secondary, .paragraphStyle: style,
        ])
        let textX = ChiefToolRowView.textX
        let h = label.size().height
        label.draw(in: NSRect(x: textX, y: ((bounds.height - h) / 2).rounded(), width: max(0, width - textX - 26), height: h))
        guard row.state != .running, row.state != .waiting else { return }
        let done = row.state == .done
        let mark = NSImage.SymbolConfiguration(pointSize: 11, weight: .medium)
            .applying(NSImage.SymbolConfiguration(paletteColors: [done ? secondary : .systemRed]))
        if let img = NSImage(systemSymbolName: done ? "checkmark" : "exclamationmark.circle.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(mark) {
            let s = img.size
            img.draw(in: NSRect(x: width - 12 - s.width, y: ((bounds.height - s.height) / 2).rounded(), width: s.width, height: s.height),
                     from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
    }
}

// MARK: Result card

final class ChiefResultCardProvider: TranscriptCustomRowProvider {
    static let shared = ChiefResultCardProvider()

    let kind = ChiefCloudRows.resultKind
    var measuresOffMain: Bool { true }
    func layout(for part: CustomPart) -> CustomRowLayout { .bubbleIncoming }

    static let padX: CGFloat = Fixture.bubblePadX
    static let padTop: CGFloat = 8
    static let padBottom: CGFloat = 10
    static let titleGap: CGFloat = 2
    static let statusGap: CGFloat = 6
    static let statusHeight: CGFloat = 16
    static let buttonGap: CGFloat = 10
    static let buttonHeight: CGFloat = 28
    static let secondaryButtonGap: CGFloat = 6
    static let secondaryButtonHeight: CGFloat = 24
    static let maxWidth: CGFloat = 340

    static let titleFont = HomeFonts.system(ofSize: 13, weight: .semibold)
    static let subtitleFont = HomeFonts.system(ofSize: 12)
    static let statusFont = HomeFonts.system(ofSize: 11, weight: .medium)

    static func text(_ s: String, font: NSFont, color: NSColor? = nil) -> NSAttributedString {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byWordWrapping
        var attrs: [NSAttributedString.Key: Any] = [.font: font, .paragraphStyle: style]
        if let color { attrs[.foregroundColor] = color }
        return NSAttributedString(string: s, attributes: attrs)
    }

    static func height(_ s: String, font: NSFont, width: CGFloat) -> CGFloat {
        ceil(text(s, font: font).boundingRect(with: CGSize(width: width, height: .greatestFiniteMagnitude),
                                              options: [.usesLineFragmentOrigin, .usesFontLeading]).height)
    }

    /// (title, subtitle) frames inside the card, and the card's size.
    static func layout(_ r: ChiefCloudRows.Result, maxWidth: CGFloat) -> (title: CGRect, subtitle: CGRect?, status: CGRect, size: CGSize) {
        let w = min(maxWidth, Self.maxWidth)
        let inner = w - 2 * padX
        var y = padTop
        let title = CGRect(x: padX, y: y, width: inner, height: height(r.title, font: titleFont, width: inner))
        y = title.maxY
        var subtitle: CGRect?
        if let s = r.subtitle {
            let frame = CGRect(x: padX, y: y + titleGap, width: inner, height: height(s, font: subtitleFont, width: inner))
            subtitle = frame
            y = frame.maxY
        }
        let status = CGRect(x: padX, y: y + statusGap, width: inner, height: statusHeight)
        y = status.maxY + buttonGap + buttonHeight + secondaryButtonGap + secondaryButtonHeight + padBottom
        return (title, subtitle, status, CGSize(width: w, height: y))
    }

    func measure(_ part: CustomPart, maxWidth: CGFloat) -> CGSize {
        guard let r = part.decode(ChiefCloudRows.Result.self) else { return CGSize(width: 220, height: 60) }
        return Self.layout(r, maxWidth: maxWidth).size
    }

    func estimate(_ part: CustomPart, maxWidth: CGFloat) -> CGSize { measure(part, maxWidth: maxWidth) }
    func makeView() -> CustomRowPlatformView { ChiefResultCardView() }

    func configure(_ view: CustomRowPlatformView, part: CustomPart, context: CustomRowContext) {
        guard let v = view as? ChiefResultCardView, let r = part.decode(ChiefCloudRows.Result.self) else { return }
        v.show(r, context: context)
    }

    func prepareForReuse(_ view: CustomRowPlatformView) { (view as? ChiefResultCardView)?.reset() }

    func handleKey(_ key: CustomRowKey, view: CustomRowPlatformView, part: CustomPart, context: CustomRowContext) -> Bool {
        guard key == .enter, let v = view as? ChiefResultCardView else { return false }
        v.open()
        return true
    }

    func plainText(_ part: CustomPart) -> String? {
        guard let r = part.decode(ChiefCloudRows.Result.self) else { return nil }
        return [r.title, r.subtitle, ChiefCloudRows.statusText(r.state) + " · " + r.shownMachine].compactMap { $0 }.joined(separator: "\n")
    }
}

/// The result card's view: drawn title, subtitle and status; the Open Workspace button.
final class ChiefResultCardView: NSView {
    private var result: ChiefCloudRows.Result?
    private var context: CustomRowContext?
    private let button = ChiefOptionButton(option: CmuxStrings.cloudOpenWorkspace, style: .prominent)
    /// Opens the machine's live display so the user can operate it when Chief should not.
    private let desktopButton = ChiefOptionButton(option: CmuxStrings.cloudOpenDesktop, style: .plain)
    /// Stop Machine: quiet, left of Open Workspace; once clicked it stays disabled (the Chief asks next).
    private let stopButton = ChiefOptionButton(option: CmuxStrings.cloudStopMachine, style: .plain)
    private var stopSent: String?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        button.target = self
        button.action = #selector(openClicked)
        button.setAccessibilityIdentifier("ChiefResultOpenWorkspace")
        addSubview(button)
        desktopButton.target = self
        desktopButton.action = #selector(desktopClicked)
        desktopButton.setAccessibilityIdentifier("ChiefResultOpenDesktop")
        addSubview(desktopButton)
        stopButton.target = self
        stopButton.action = #selector(stopClicked)
        stopButton.setAccessibilityIdentifier("ChiefResultStopMachine")
        addSubview(stopButton)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityRoleDescription(CmuxStrings.cloudResultRole)
        setAccessibilityIdentifier("ChiefResultCard")
    }
    required init?(coder: NSCoder) { nil }
    override var isFlipped: Bool { true }

    func reset() {
        result = nil
        context = nil
        stopSent = nil
        stopButton.isEnabled = true
        desktopButton.isEnabled = true
    }

    func show(_ r: ChiefCloudRows.Result, context: CustomRowContext) {
        if result?.machine != r.machine || result?.workspace != r.workspace {
            stopSent = nil
        }
        stopButton.isEnabled = stopSent == nil
        result = r
        self.context = context
        button.restyle() // the theme's accent may have changed
        button.toolTip = "cmux vm workspace open \(r.machine) \(r.workspace)"
        desktopButton.restyle()
        desktopButton.toolTip = "cmux vm desktop \(r.machine)"
        stopButton.restyle()
        stopButton.toolTip = "cmux vm pause \(r.machine)"
        setAccessibilityLabel(r.title)
        setAccessibilityValue(ChiefCloudRows.statusText(r.state))
        // The card shows the machine's name; its raw id is here (and in the button's command).
        toolTip = r.name != nil ? r.machine : nil
        needsLayout = true
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        let p = ChiefResultCardProvider.self
        let w = max(120, ceil(button.intrinsicContentSize.width) + 28)
        let secondaryY = bounds.height - p.padBottom - p.secondaryButtonHeight
        let y = secondaryY - p.secondaryButtonGap - p.buttonHeight
        button.frame = NSRect(x: bounds.width - p.padX - w, y: y, width: w, height: p.buttonHeight)
        let desktopWidth = ceil(desktopButton.intrinsicContentSize.width) + 20
        desktopButton.frame = NSRect(x: p.padX, y: secondaryY, width: desktopWidth, height: p.secondaryButtonHeight)
        let stopWidth = ceil(stopButton.intrinsicContentSize.width) + 20
        let stopX = desktopButton.frame.maxX + p.secondaryButtonGap
        stopButton.frame = NSRect(x: stopX, y: secondaryY, width: stopWidth, height: p.secondaryButtonHeight)
        stopButton.isHidden = stopX + stopWidth > bounds.width - p.padX
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let r = result else { return }
        let p = ChiefResultCardProvider.self
        let l = p.layout(r, maxWidth: bounds.width)
        p.text(r.title, font: p.titleFont, color: Fixture.incomingText)
            .draw(with: l.title, options: [.usesLineFragmentOrigin, .usesFontLeading])
        if let s = r.subtitle, let frame = l.subtitle {
            p.text(s, font: p.subtitleFont, color: Fixture.secondaryText).draw(with: frame, options: [.usesLineFragmentOrigin, .usesFontLeading])
        }
        // The state: a coloured dot, the state and the machine.
        let dot: NSColor
        switch r.state {
        case .running: dot = .systemGreen
        case .waiting: dot = .systemOrange
        case .done: dot = Fixture.secondaryText
        case .failed: dot = .systemRed
        }
        let d: CGFloat = 7
        let dotRect = NSRect(x: l.status.minX, y: (l.status.midY - d / 2).rounded(), width: d, height: d)
        dot.setFill()
        NSBezierPath(ovalIn: dotRect).fill()
        let status = NSMutableAttributedString(string: ChiefCloudRows.statusText(r.state) + " · ", attributes: [
            .font: p.statusFont, .foregroundColor: Fixture.secondaryText,
        ])
        status.append(NSAttributedString(string: r.shownMachine, attributes: [
            .font: HomeFonts.monospaced(ofSize: 11), .foregroundColor: Fixture.secondaryText,
        ]))
        let h = status.size().height
        status.draw(in: NSRect(x: dotRect.maxX + 6, y: (l.status.midY - h / 2).rounded(), width: l.status.width - d - 6, height: h))
    }

    @objc private func openClicked() { open() }

    @objc private func desktopClicked() {
        guard let r = result, let intents = hostIntents else { return }
        intents.openCloudDesktop(machine: r.machine)
    }

    /// Stop Machine: the Chief hears "Stop cloud machine <name> (<id>)" and asks with its approval
    /// card before `cmux vm pause` runs. The button stays off for this card once sent.
    @objc private func stopClicked() {
        guard let r = result, stopSent == nil, let intents = hostIntents else { return }
        stopSent = r.machine
        stopButton.isEnabled = false
        intents.stopCloudMachine(machine: r.machine, name: r.shownMachine) { [weak self] ok in
            guard let self, !ok, self.stopSent == r.machine else { return }
            self.stopSent = nil
            self.stopButton.isEnabled = true
        }
    }

    /// Opens the machine workspace (the button, or Return while the card has the focus).
    func open() {
        guard let r = result, let intents = hostIntents else { return }
        intents.openCloudWorkspace(machine: r.machine, workspace: r.workspace)
    }

    private var hostIntents: ChatIntents? {
        var v: NSView? = self
        while let view = v {
            if let host = view as? HostView { return host.controller?.intents }
            v = view.superview
        }
        return nil
    }
}
