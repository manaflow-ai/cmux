public import AppKit
public import CmuxNextComputerUse
import CmuxNextDesign

/// The approval cards (docs/computer-use-approvals.md, Collectors): one cmux dialog per waiting
/// question, each in its own floating, non-activating panel at the top right of the main screen,
/// stacked downward. A card shows over every app and never takes the frontmost app or the
/// keyboard by itself; once the person clicks it, its keys work (Return: Allow Once, Escape:
/// Deny, Command-S: Allow for This Session, Command-A: Always Allow). Only a press on a card
/// answers from here.
@MainActor
public final class ComputerUseApprovalCards: ComputerUseApprovalPresenting {
    /// One shown card.
    private struct Card {
        var dialog: Int
        var panel: NSPanel?
    }

    /// The cards' own dialog center: its host puts each dialog in its card panel.
    let center: CmuxDialogCenter
    private var cards: [String: Card] = [:]
    /// Card ids, oldest first (the stacking order).
    private var order: [String] = []
    /// Cards whose icon is still loading (withdrawn meanwhile: never shown).
    private var loading: Set<String> = []
    /// Builds a card's panel; tests pass nil to keep cards off screen.
    private let makesPanels: Bool

    public convenience init() {
        self.init(panels: true)
    }

    init(panels: Bool) {
        makesPanels = panels
        if panels {
            let host = ComputerUseApprovalCardHost()
            center = CmuxDialogCenter(host: host)
            host.placed = { [weak self] in self?.restack() }
        } else {
            center = CmuxDialogCenter(host: CmuxDialogHeadlessHost())
        }
    }

    /// The dialog of question `id` (tests, automation), if its card shows.
    func dialogID(_ id: String) -> Int? { cards[id]?.dialog }

    public func show(_ pending: ComputerUseApprovalPending, broker: ComputerUseApprovalBroker) {
        if let card = cards[pending.id] {
            card.panel?.orderFrontRegardless()
            return
        }
        guard !loading.contains(pending.id) else { return }
        loading.insert(pending.id)
        let target = pending.request.target
        guard makesPanels else { return present(pending, icon: nil, broker: broker) }
        // task-owner: one icon read per card, off the main actor; a withdrawn card is not shown.
        Task { [weak self, weak broker] in
            let icon = await Task.detached(priority: .userInitiated) { Self.icon(for: target) }.value
            guard let self, let broker else { return }
            present(pending, icon: icon, broker: broker)
        }
    }

    public func withdraw(_ id: String) {
        loading.remove(id)
        guard let card = cards.removeValue(forKey: id) else { return }
        order.removeAll { $0 == id }
        _ = center.dismiss(card.dialog)
        card.panel?.close()
        restack()
    }

    private func present(_ pending: ComputerUseApprovalPending, icon: Data?, broker: ComputerUseApprovalBroker) {
        guard loading.remove(pending.id) != nil, broker.pending.contains(where: { $0.id == pending.id }) else { return }
        let spec = Self.spec(for: pending.request, icon: icon)
        let id = pending.id
        let panel = makesPanels ? ComputerUseApprovalCardPanel.make() : nil
        let scope: CmuxDialogScope = panel.map { .window($0) } ?? .app
        let dialog = center.present(spec, in: scope) { [weak self, weak broker] answer in
            guard let self, cards[id] != nil else { return }
            // A dismissal (the card withdrawn, its panel closed) decides nothing.
            if !answer.isDismissal, let decision = ComputerUseApprovalDecision(rawValue: answer.button) {
                broker?.decide(id, decision: decision)
            }
            withdraw(id)
        }
        cards[id] = Card(dialog: dialog, panel: panel)
        order.append(id)
        restack()
    }

    /// The card's dialog: who asks (agent, workspace, cmux client), the app (icon and name),
    /// until when, and the four answers.
    static func spec(for request: ComputerUseApprovalRequest, icon: Data?, timeZone: TimeZone = .current) -> CmuxDialogSpec {
        let app = request.target.name.isEmpty ? (request.target.bundleID ?? request.target.executable ?? "") : request.target.name
        let formatter = DateFormatter()
        formatter.timeZone = timeZone
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        let until = formatter.string(from: Date(timeIntervalSince1970: TimeInterval(request.answerableUntilMs) / 1000))
        return CmuxDialogSpec(
            title: ComputerUseApprovalStrings.title(agent: request.agent, app: app),
            lines: [ComputerUseApprovalStrings.asker(agent: request.agent, workspace: request.workspace),
                    request.target.bundleID ?? request.target.executable ?? "",
                    ComputerUseApprovalStrings.client(request.client),
                    ComputerUseApprovalStrings.expires(until)],
            buttons: [
                CmuxDialogButton(id: ComputerUseApprovalDecision.deny.rawValue, title: ComputerUseApprovalStrings.deny, role: .cancel),
                // No Return default and no Command key on an allow: a stray key never grants.
                CmuxDialogButton(id: ComputerUseApprovalDecision.always.rawValue, title: ComputerUseApprovalStrings.allowAlways(app), role: .normal),
                CmuxDialogButton(id: ComputerUseApprovalDecision.session.rawValue, title: ComputerUseApprovalStrings.allowSession, role: .normal),
                CmuxDialogButton(id: ComputerUseApprovalDecision.once.rawValue, title: ComputerUseApprovalStrings.allowOnce, role: .normal),
            ],
            icon: icon,
            identifier: "cmux.dialog.computerUse.approval")
    }

    /// The target app's icon as TIFF data, nil when it cannot be found.
    nonisolated static func icon(for app: ComputerUseApprovalApp) -> Data? {
        let workspace = NSWorkspace.shared
        let path = app.bundleID.flatMap { workspace.urlForApplication(withBundleIdentifier: $0)?.path } ?? app.executable
        guard let path else { return nil }
        let image = workspace.icon(forFile: path)
        image.size = NSSize(width: 64, height: 64)
        return image.tiffRepresentation
    }

    /// Places the cards at the top right of the main screen, oldest on top.
    private func restack() {
        let screen = NSScreen.main ?? NSScreen.screens.first
        guard let area = screen?.visibleFrame else { return }
        var top = area.maxY - 16
        for id in order {
            guard let panel = cards[id]?.panel, let content = panel.contentView else { continue }
            let size = content.fittingSize
            let frame = CGRect(x: area.maxX - size.width - 16, y: top - size.height, width: size.width, height: size.height)
            panel.setFrame(frame, display: true)
            top = frame.minY - 8
            panel.orderFrontRegardless()
        }
    }
}

/// A card's panel: floating over every app and Space, non-activating. It may become key only
/// after the person clicked in it (so its keys work then): a card never takes the keyboard on its
/// own, also not when another card closes and AppKit picks the next key window.
@MainActor
final class ComputerUseApprovalCardPanel: NSPanel {
    private var clicked = false
    override var canBecomeKey: Bool { clicked }
    override var canBecomeMain: Bool { false }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown || event.type == .rightMouseDown { clicked = true }
        super.sendEvent(event)
    }

    static func make() -> ComputerUseApprovalCardPanel {
        let panel = ComputerUseApprovalCardPanel(contentRect: CGRect(x: 0, y: 0, width: 420, height: 200),
                                                 styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: true)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        return panel
    }
}

/// Puts each card's dialog view in its own panel (the scope's window).
@MainActor
final class ComputerUseApprovalCardHost: CmuxDialogHosting {
    /// A card was placed or removed: the cards restack.
    var placed: () -> Void = {}

    func show(_ dialog: CmuxDialogView, in scope: CmuxDialogScope, scopeGone: @escaping () -> Void) {
        guard case .window(let panel) = scope else { return }
        dialog.layoutSubtreeIfNeeded()
        let size = dialog.fittingSize
        dialog.translatesAutoresizingMaskIntoConstraints = true
        dialog.autoresizingMask = [.width, .height]
        dialog.frame = NSRect(origin: .zero, size: size)
        let container = NSView(frame: NSRect(origin: .zero, size: size))
        container.addSubview(dialog)
        panel.contentView = container
        panel.setContentSize(size)
        placed()
    }

    func hide(_ dialog: CmuxDialogView) {
        dialog.window?.orderOut(nil)
        dialog.removeFromSuperview()
        placed()
    }
}
