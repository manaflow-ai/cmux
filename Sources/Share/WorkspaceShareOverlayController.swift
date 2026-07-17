import AppKit
import Foundation

/// Fixed participant palette shared with the web viewer (index = participant
/// `color`; host is 0).
enum WorkspaceShareParticipantPalette {
    static let colors: [NSColor] = [
        NSColor(srgbRed: 0.35, green: 0.62, blue: 1.00, alpha: 1),  // sky (host)
        NSColor(srgbRed: 1.00, green: 0.45, blue: 0.42, alpha: 1),
        NSColor(srgbRed: 0.45, green: 0.85, blue: 0.55, alpha: 1),
        NSColor(srgbRed: 1.00, green: 0.75, blue: 0.30, alpha: 1),
        NSColor(srgbRed: 0.80, green: 0.55, blue: 1.00, alpha: 1),
        NSColor(srgbRed: 0.35, green: 0.85, blue: 0.90, alpha: 1),
        NSColor(srgbRed: 1.00, green: 0.55, blue: 0.80, alpha: 1),
        NSColor(srgbRed: 0.75, green: 0.85, blue: 0.35, alpha: 1),
    ]

    static func color(forIndex index: Int) -> NSColor {
        colors[((index % colors.count) + colors.count) % colors.count]
    }
}

/// Non-activating, mouse-transparent child window layered over the shared
/// workspace's window. Renders remote participants' kite cursors, name chips,
/// and cursor-chat bubbles (same overlay approach as the computer-use cursor
/// overlay). Positions use the share protocol's normalized [0,1] workspace
/// coordinates mapped through the live bonsplit container frame.
@MainActor
final class WorkspaceShareOverlayController {
    private var overlayWindow: NSWindow?
    private weak var hostWindow: NSWindow?
    private weak var workspace: Workspace?
    private var cursorViews: [String: ShareCursorView] = [:]
    private var participantsById: [String: ShareParticipant] = [:]
    private var chatDismissTasks: [String: Task<Void, Never>] = [:]

    func attach(to window: NSWindow?, workspace: Workspace) {
        detach()
        guard let window else { return }
        self.workspace = workspace
        hostWindow = window

        let overlay = NSWindow(
            contentRect: window.frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        overlay.isOpaque = false
        overlay.backgroundColor = .clear
        overlay.ignoresMouseEvents = true
        overlay.hasShadow = false
        overlay.level = window.level
        overlay.collectionBehavior = [.fullScreenAuxiliary, .transient]
        overlay.contentView = NSView(frame: NSRect(origin: .zero, size: window.frame.size))
        window.addChildWindow(overlay, ordered: .above)
        overlayWindow = overlay
    }

    func detach() {
        for task in chatDismissTasks.values { task.cancel() }
        chatDismissTasks.removeAll()
        cursorViews.removeAll()
        participantsById.removeAll()
        if let overlayWindow {
            overlayWindow.parent?.removeChildWindow(overlayWindow)
            overlayWindow.orderOut(nil)
        }
        overlayWindow = nil
        hostWindow = nil
        workspace = nil
    }

    func updateParticipants(_ participants: [ShareParticipant]) {
        participantsById = Dictionary(uniqueKeysWithValues: participants.map { ($0.id, $0) })
        // Remove cursors for departed participants.
        for (id, view) in cursorViews where participantsById[id] == nil {
            view.removeFromSuperview()
            cursorViews[id] = nil
            chatDismissTasks[id]?.cancel()
            chatDismissTasks[id] = nil
        }
        for (id, view) in cursorViews {
            if let participant = participantsById[id] {
                view.apply(participant: participant)
            }
        }
    }

    func updateRemoteCursor(participantId: String, x: Double, y: Double) {
        guard !participantId.isEmpty,
              let point = windowPoint(normalizedX: x, normalizedY: y),
              let contentView = overlayWindow?.contentView else { return }
        let view = cursorView(for: participantId, in: contentView)
        view.setFrameOrigin(NSPoint(x: point.x, y: point.y - view.frame.height))
        view.isHidden = false
    }

    func showChat(participantId: String, text: String, x: Double, y: Double) {
        guard !text.isEmpty else { return }
        updateRemoteCursor(participantId: participantId, x: x, y: y)
        guard let view = cursorViews[participantId] else { return }
        view.showBubble(text: text)
        chatDismissTasks[participantId]?.cancel()
        chatDismissTasks[participantId] = Task { [weak view, weak self] in
            // Intentional bounded auto-dismiss delay; cancelled by newer
            // messages and by detach().
            try? await ContinuousClock().sleep(for: .seconds(6))
            guard !Task.isCancelled else { return }
            view?.hideBubble()
            self?.chatDismissTasks[participantId] = nil
        }
    }

    // MARK: - Geometry

    /// Maps normalized share coordinates (top-left origin) to overlay-window
    /// view coordinates (bottom-left origin), using the live container frame.
    private func windowPoint(normalizedX: Double, normalizedY: Double) -> CGPoint? {
        guard let workspace, let hostWindow, let contentView = hostWindow.contentView else { return nil }
        let snapshot = workspace.bonsplitController.layoutSnapshot()
        let container = snapshot.containerFrame
        guard container.width > 0, container.height > 0 else { return nil }
        let topLeftX = container.x + normalizedX * container.width
        let topLeftY = container.y + normalizedY * container.height
        // Overlay window tracks the host window frame, so content-view local
        // coordinates line up 1:1 after the y-axis flip.
        return CGPoint(x: topLeftX, y: Double(contentView.bounds.height) - topLeftY)
    }

    private func cursorView(for participantId: String, in contentView: NSView) -> ShareCursorView {
        if let existing = cursorViews[participantId] { return existing }
        let view = ShareCursorView()
        if let participant = participantsById[participantId] {
            view.apply(participant: participant)
        }
        contentView.addSubview(view)
        cursorViews[participantId] = view
        return view
    }

    /// Host-window frame changes (move/resize) must retarget the overlay.
    func hostWindowFrameDidChange() {
        guard let overlayWindow, let hostWindow else { return }
        overlayWindow.setFrame(hostWindow.frame, display: false)
        overlayWindow.contentView?.frame = NSRect(origin: .zero, size: hostWindow.frame.size)
    }
}

/// One remote participant's kite cursor + name chip + optional chat bubble.
@MainActor
final class ShareCursorView: NSView {
    private let kiteLayer = CAShapeLayer()
    private let nameField = NSTextField(labelWithString: "")
    private let bubbleField = NSTextField(wrappingLabelWithString: "")
    private let bubbleBackground = NSView()
    private var tint: NSColor = WorkspaceShareParticipantPalette.color(forIndex: 1)

    private static let kiteSize: CGFloat = 18
    private static let maxBubbleWidth: CGFloat = 240

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 260, height: 120))
        wantsLayer = true

        // Kite pointer: a simple four-point kite path (stand-in matching the
        // web viewer's inline SVG shape), tip at the view's top-left.
        let path = CGMutablePath()
        let s = Self.kiteSize
        path.move(to: CGPoint(x: 0, y: 0))
        path.addLine(to: CGPoint(x: s * 0.85, y: -s * 0.35))
        path.addLine(to: CGPoint(x: s * 0.45, y: -s * 0.45))
        path.addLine(to: CGPoint(x: s * 0.35, y: -s))
        path.closeSubpath()
        kiteLayer.path = path
        kiteLayer.strokeColor = NSColor.white.withAlphaComponent(0.9).cgColor
        kiteLayer.lineWidth = 1
        kiteLayer.position = CGPoint(x: 0, y: frame.height)
        layer?.addSublayer(kiteLayer)

        nameField.font = NSFont.systemFont(ofSize: 10, weight: .semibold)
        nameField.textColor = .white
        nameField.wantsLayer = true
        nameField.drawsBackground = false
        addSubview(nameField)

        bubbleBackground.wantsLayer = true
        bubbleBackground.layer?.cornerRadius = 8
        bubbleBackground.isHidden = true
        addSubview(bubbleBackground)
        bubbleField.font = NSFont.systemFont(ofSize: 11)
        bubbleField.textColor = .white
        bubbleField.maximumNumberOfLines = 4
        bubbleField.isHidden = true
        addSubview(bubbleField)

        applyTint()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }

    func apply(participant: ShareParticipant) {
        tint = WorkspaceShareParticipantPalette.color(forIndex: participant.color)
        let label = participant.name.isEmpty ? participant.email : participant.name
        nameField.stringValue = label
        applyTint()
        layoutChrome()
    }

    func showBubble(text: String) {
        bubbleField.stringValue = text
        bubbleField.isHidden = false
        bubbleBackground.isHidden = false
        layoutChrome()
    }

    func hideBubble() {
        bubbleField.isHidden = true
        bubbleBackground.isHidden = true
    }

    private func applyTint() {
        kiteLayer.fillColor = tint.cgColor
        nameField.layer?.backgroundColor = tint.withAlphaComponent(0.9).cgColor
        nameField.layer?.cornerRadius = 4
        bubbleBackground.layer?.backgroundColor = tint.withAlphaComponent(0.85).cgColor
    }

    private func layoutChrome() {
        nameField.sizeToFit()
        var nameFrame = nameField.frame
        nameFrame.origin = CGPoint(x: Self.kiteSize + 4, y: 2)
        nameFrame.size.width += 8
        nameFrame.size.height += 2
        nameField.frame = nameFrame
        nameField.alignment = .center

        if !bubbleField.isHidden {
            let fit = bubbleField.sizeThatFits(
                NSSize(width: Self.maxBubbleWidth, height: .greatestFiniteMagnitude)
            )
            let bubbleFrame = NSRect(
                x: Self.kiteSize + 4,
                y: nameFrame.maxY + 4,
                width: min(fit.width, Self.maxBubbleWidth) + 16,
                height: fit.height + 12
            )
            bubbleBackground.frame = bubbleFrame
            bubbleField.frame = bubbleFrame.insetBy(dx: 8, dy: 6)
        }
    }
}
