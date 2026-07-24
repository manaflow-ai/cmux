import AppKit
import CmuxWorkspaceShare
import Foundation

/// Renders remote guest cursors over the Mac's terminal panes and forwards
/// the host's own pointer position while it is over a shared workspace pane.
///
/// The session controller injects pane-view resolution and workspace
/// visibility so this type stays free of workspace-model knowledge. Cursors
/// for non-visible workspaces are hidden (only the selected workspace's panes
/// are mounted).
@MainActor
final class ShareCursorOverlayController {
    /// Fixed participant color palette (host is index 0).
    static let palette: [NSColor] = [
        "#2d8cff", "#ff5c93", "#3ecf6e", "#ffb02e",
        "#b06cff", "#00c2c7", "#ff7a45", "#e0d75a",
    ].map { NSColor(shareHex: $0) }

    static func color(forIndex index: Int) -> NSColor {
        let palette = Self.palette
        guard !palette.isEmpty else { return .systemBlue }
        return palette[((index % palette.count) + palette.count) % palette.count]
    }

    private struct RemoteCursor {
        var email: String
        var colorIndex: Int
        var pos: ShareCursorPos?
        var bubbleText: String?
    }

    /// Resolve the pane's live content view for `(ws, pane)` UUID strings.
    var resolvePaneView: ((_ ws: String, _ pane: String) -> NSView?)?
    /// Whether the workspace is the visible (selected) one.
    var isWorkspaceVisible: ((_ ws: String) -> Bool)?
    /// Host cursor position outbound (nil = pointer left the shared area).
    var sendHostCursor: ((ShareCursorPos?) -> Void)?
    /// Maps a mouse event to a pane-relative cursor position over a shared
    /// workspace pane, or nil when the pointer is elsewhere.
    var hostCursorPosition: ((NSEvent) -> ShareCursorPos?)?

    private var cursorsByUser: [String: RemoteCursor] = [:]
    private var viewsByUser: [String: ShareCursorPointerView] = [:]
    private var bubbleExpiryTasks: [String: Task<Void, Never>] = [:]
    private var bubbleGenerations: [String: UInt64] = [:]
    private var nextBubbleGeneration: UInt64 = 1
    private var mouseMonitor: Any?
    private var lastHostSendUptime: TimeInterval = 0
    private var lastHostSendWasNil = true
    private static let hostSendMinInterval: TimeInterval = 1.0 / 30.0
    private let bubbleLifetime: Duration

    init(bubbleLifetime: Duration = .seconds(5)) {
        self.bubbleLifetime = bubbleLifetime
    }

    // MARK: - Remote cursors in

    var remoteUserIDs: Set<String> {
        Set(cursorsByUser.keys)
    }

    func updateRemoteCursor(user: String, email: String, colorIndex: Int, pos: ShareCursorPos?) {
        let existing = cursorsByUser[user]
        if pos == nil {
            clearRemoteBubble(user: user)
        }
        cursorsByUser[user] = RemoteCursor(
            email: email,
            colorIndex: colorIndex,
            pos: pos,
            bubbleText: pos == nil ? nil : existing?.bubbleText
        )
        reposition(user: user)
    }

    /// Presents one already-admitted guest bubble at its validated terminal
    /// anchor. The overlay keeps only a bounded display prefix; panel chat
    /// retains the complete protocol-bounded message.
    @discardableResult
    func showRemoteBubble(
        user: String,
        email: String,
        colorIndex: Int,
        text: String,
        anchor: ShareCursorPos
    ) -> Bool {
        guard !text.isEmpty,
              text.utf8.count <= ShareProtocolConstants.maximumChatTextBytes,
              anchor.x.isFinite,
              anchor.y.isFinite,
              (0...1).contains(anchor.x),
              (0...1).contains(anchor.y),
              resolvePaneView?(anchor.ws, anchor.pane) != nil else {
            return false
        }

        let boundedText = ShareCursorPointerView.boundedBubbleText(text)
        var cursor = cursorsByUser[user] ?? RemoteCursor(
            email: email,
            colorIndex: colorIndex,
            pos: anchor,
            bubbleText: nil
        )
        cursor.email = email
        cursor.colorIndex = colorIndex
        cursor.pos = anchor
        cursor.bubbleText = boundedText
        cursorsByUser[user] = cursor

        bubbleExpiryTasks.removeValue(forKey: user)?.cancel()
        let generation = nextBubbleGeneration
        nextBubbleGeneration &+= 1
        bubbleGenerations[user] = generation
        let lifetime = bubbleLifetime
        bubbleExpiryTasks[user] = Task { @MainActor [weak self] in
            do {
                try await ContinuousClock().sleep(for: lifetime)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            self?.expireRemoteBubble(user: user, generation: generation)
        }
        reposition(user: user)
        return true
    }

    /// Generation matching prevents a cancelled timer from clearing a newer
    /// bubble from the same participant.
    func expireRemoteBubble(user: String, generation: UInt64) {
        guard bubbleGenerations[user] == generation else { return }
        bubbleGenerations.removeValue(forKey: user)
        bubbleExpiryTasks.removeValue(forKey: user)
        guard var cursor = cursorsByUser[user] else { return }
        cursor.bubbleText = nil
        cursorsByUser[user] = cursor
        viewsByUser[user]?.setBubbleText(nil)
    }

    func remoteBubbleText(for user: String) -> String? {
        cursorsByUser[user]?.bubbleText
    }

    func remoteBubbleGeneration(for user: String) -> UInt64? {
        bubbleGenerations[user]
    }

    func removeRemoteUser(_ user: String) {
        clearRemoteBubble(user: user)
        cursorsByUser.removeValue(forKey: user)
        viewsByUser.removeValue(forKey: user)?.removeFromSuperview()
    }

    /// Re-evaluates every cursor's visibility (workspace selection changed,
    /// layout changed).
    func refreshAll() {
        for user in cursorsByUser.keys {
            reposition(user: user)
        }
    }

    func teardown() {
        uninstallMouseMonitor()
        for task in bubbleExpiryTasks.values {
            task.cancel()
        }
        bubbleExpiryTasks.removeAll()
        bubbleGenerations.removeAll()
        for view in viewsByUser.values {
            view.removeFromSuperview()
        }
        viewsByUser.removeAll()
        cursorsByUser.removeAll()
    }

    private func reposition(user: String) {
        guard let cursor = cursorsByUser[user] else {
            viewsByUser.removeValue(forKey: user)?.removeFromSuperview()
            return
        }
        guard let pos = cursor.pos,
              isWorkspaceVisible?(pos.ws) == true,
              let paneView = resolvePaneView?(pos.ws, pos.pane),
              paneView.window != nil else {
            viewsByUser[user]?.removeFromSuperview()
            return
        }
        let view = ensureView(user: user, cursor: cursor)
        if view.superview !== paneView {
            view.removeFromSuperview()
            paneView.addSubview(view, positioned: .above, relativeTo: nil)
        }
        let bounds = paneView.bounds
        let x = bounds.minX + pos.x.clampedUnit * bounds.width
        let yFromTop = pos.y.clampedUnit * bounds.height
        let y = paneView.isFlipped
            ? bounds.minY + yFromTop
            : bounds.maxY - yFromTop - view.frame.height
        view.setFrameOrigin(NSPoint(x: x, y: y))
        view.isHidden = false
    }

    private func clearRemoteBubble(user: String) {
        bubbleExpiryTasks.removeValue(forKey: user)?.cancel()
        bubbleGenerations.removeValue(forKey: user)
        if var cursor = cursorsByUser[user] {
            cursor.bubbleText = nil
            cursorsByUser[user] = cursor
        }
        viewsByUser[user]?.setBubbleText(nil)
    }

    private func ensureView(user: String, cursor: RemoteCursor) -> ShareCursorPointerView {
        if let existing = viewsByUser[user] {
            existing.setName(cursor.email)
            existing.setBubbleText(cursor.bubbleText)
            return existing
        }
        let view = ShareCursorPointerView(
            color: Self.color(forIndex: cursor.colorIndex),
            name: cursor.email
        )
        view.setBubbleText(cursor.bubbleText)
        viewsByUser[user] = view
        return view
    }

    // MARK: - Host cursor out

    /// Installs a local `.mouseMoved`/`.mouseDragged` monitor while sharing.
    /// Sends are timer-less throttled to ~30 Hz: events within 33 ms of the
    /// last send are dropped.
    func installMouseMonitor() {
        guard mouseMonitor == nil else { return }
        mouseMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]
        ) { [weak self] event in
            MainActor.assumeIsolated {
                self?.handleHostMouseEvent(event)
            }
            return event
        }
    }

    func uninstallMouseMonitor() {
        if let mouseMonitor {
            NSEvent.removeMonitor(mouseMonitor)
        }
        mouseMonitor = nil
        lastHostSendWasNil = true
    }

    private func handleHostMouseEvent(_ event: NSEvent) {
        let pos = hostCursorPosition?(event)
        if pos == nil {
            // Leaving the shared area is a state change, not a stream; send it
            // once regardless of the throttle window.
            guard !lastHostSendWasNil else { return }
            lastHostSendWasNil = true
            sendHostCursor?(nil)
            return
        }
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastHostSendUptime >= Self.hostSendMinInterval else { return }
        lastHostSendUptime = now
        lastHostSendWasNil = false
        sendHostCursor?(pos)
    }
}

private extension Double {
    var clampedUnit: Double { Swift.min(Swift.max(self, 0), 1) }
}

private extension NSColor {
    /// Parses `#rrggbb` (falls back to systemBlue for malformed input).
    convenience init(shareHex hex: String) {
        var value: UInt64 = 0
        let scanner = Scanner(string: String(hex.dropFirst()))
        guard hex.hasPrefix("#"), scanner.scanHexInt64(&value) else {
            self.init(srgbRed: 0.18, green: 0.55, blue: 1.0, alpha: 1.0)
            return
        }
        self.init(
            srgbRed: CGFloat((value >> 16) & 0xFF) / 255.0,
            green: CGFloat((value >> 8) & 0xFF) / 255.0,
            blue: CGFloat(value & 0xFF) / 255.0,
            alpha: 1.0
        )
    }
}
