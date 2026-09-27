import AppKit
import CmuxSidebar
import Foundation
import SwiftUI

/// The single leading glyph a workspace row shows when
/// `sidebar.compactAgentStatus` is on, modeled on the Claude desktop session
/// list: every row is one line, glyph then title, with the details in the
/// glyph's tooltip. Agent hooks report their lifecycle as keyed status
/// entries (`set_status claude_code Running --icon=bolt.fill`); compact mode
/// drops those agent-owned rows, the branch/directory line and the pull
/// request rows, and folds all of it into the glyph. Other status entries
/// stay as metadata rows.
///
/// Precedence, loudest first:
/// 1. Error (an agent reported a failure): red warning triangle. Only for
///    something that broke.
/// 2. Needs input: yellow dot.
/// 3. Running: pulsing gray dot. It replaces the row's loading spinner.
/// 4. Starting (agent present, state not reported yet): hollow ring.
/// 5. Done and unseen (unread notifications): blue dot. Applied by the row,
///    which owns the unread count; see ``applyingUnread(_:latestNotificationText:)``.
/// 6. Pull request: merged purple; open orange with a "!" badge on a merge
///    conflict, red with an "x" badge when CI fails, green with a check badge
///    when CI passes, gray while checks are unknown; closed gray with a minus.
/// 7. Agent idle (done and seen): gray checkmark.
/// 8. Branch, no pull request: gray branch.
/// 9. Otherwise, a plain terminal: gray terminal.
/// Only the three agent states Claude marks with dots (needs input, unseen,
/// running) are dots; everything settled gets a symbol that says what it is.
struct SidebarCompactStatusGlyph: Equatable {
    enum Kind: Equatable {
        case error
        case needsInput
        case running
        case pending
        case unseen
        case pullRequest(PullRequestState)
        case idle
        case branch
        case terminal
    }

    enum PullRequestState: Equatable {
        case open(Checks?)
        case merged
        case closed
    }

    /// CI and mergeability of an open pull request, when known.
    enum Checks: Equatable {
        case passing
        case failing
        case conflict
    }

    let kind: Kind
    /// One line per fact: agent statuses, pull requests, branch, directory.
    let tooltip: String
    /// `sidebar.compactStatusIcons`: SF Symbol names by ``IconSlot`` raw value.
    var iconOverrides: [String: String] = [:]

    /// The customizable states; raw values are the `sidebar.compactStatusIcons`
    /// keys in cmux.json.
    enum IconSlot: String, CaseIterable {
        case error
        case needsInput
        case running
        case starting
        case unseen
        case pullRequestOpen
        case pullRequestPassing
        case pullRequestFailing
        case pullRequestConflict
        case pullRequestMerged
        case pullRequestClosed
        case idle
        case branch
        case terminal
    }

    var iconSlot: IconSlot {
        switch kind {
        case .error: return .error
        case .needsInput: return .needsInput
        case .running: return .running
        case .pending: return .starting
        case .unseen: return .unseen
        case .pullRequest(.open(nil)): return .pullRequestOpen
        case .pullRequest(.open(.passing)): return .pullRequestPassing
        case .pullRequest(.open(.failing)): return .pullRequestFailing
        case .pullRequest(.open(.conflict)): return .pullRequestConflict
        case .pullRequest(.merged): return .pullRequestMerged
        case .pullRequest(.closed): return .pullRequestClosed
        case .idle: return .idle
        case .branch: return .branch
        case .terminal: return .terminal
        }
    }

    /// Keeps entries whose key names a state and whose symbol name is not blank.
    static func validIconOverrides(_ raw: [String: String]) -> [String: String] {
        var valid: [String: String] = [:]
        for (key, value) in raw where IconSlot(rawValue: key) != nil {
            let symbol = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !symbol.isEmpty { valid[key] = symbol }
        }
        return valid
    }

    /// The configured symbol for this state, or nil for the built-in one.
    var customSymbolName: String? {
        iconOverrides[iconSlot.rawValue]
    }

    /// The symbol drawn: the configured one, else the built-in default.
    var symbolName: String {
        customSymbolName ?? defaultSymbolName
    }

    var defaultSymbolName: String {
        switch kind {
        case .error: return "exclamationmark.triangle.fill"
        case .pullRequest(.merged): return "arrow.triangle.merge"
        case .pullRequest: return "arrow.triangle.pull"
        case .pending: return "circle.dashed"
        case .needsInput, .running, .unseen: return "circle.fill"
        case .idle: return "checkmark.circle"
        case .branch: return "arrow.triangle.branch"
        case .terminal: return "terminal"
        }
    }

    /// A small symbol knocked into the glyph's lower trailing corner, for the
    /// pull request states that share one base glyph.
    var badgeSymbolName: String? {
        // A configured symbol replaces the whole glyph, badge included.
        guard customSymbolName == nil else { return nil }
        switch kind {
        case .pullRequest(.open(.passing)): return "checkmark.circle.fill"
        case .pullRequest(.open(.failing)): return "xmark.circle.fill"
        case .pullRequest(.open(.conflict)): return "exclamationmark.circle.fill"
        case .pullRequest(.closed): return "minus.circle.fill"
        default: return nil
        }
    }

    /// Whether the glyph pulses (the running indicator).
    var pulses: Bool { kind == .running }

    /// Unread notifications turn a settled row blue; agent activity and
    /// errors stay louder. The latest notification leads the tooltip, since
    /// compact rows hide the notification preview line and the count badge.
    func applyingUnread(_ unreadCount: Int, latestNotificationText: String?) -> SidebarCompactStatusGlyph {
        guard unreadCount > 0 else { return self }
        let text = latestNotificationText?.trimmingCharacters(in: .whitespacesAndNewlines)
        let unreadTooltip = [text, tooltip]
            .compactMap { $0?.isEmpty == false ? $0 : nil }
            .joined(separator: "\n")
        switch kind {
        case .pullRequest, .idle, .branch, .terminal:
            return SidebarCompactStatusGlyph(kind: .unseen, tooltip: unreadTooltip, iconOverrides: iconOverrides)
        case .error, .needsInput, .running, .pending, .unseen:
            return SidebarCompactStatusGlyph(kind: kind, tooltip: unreadTooltip, iconOverrides: iconOverrides)
        }
    }

    /// The pure inputs, captured by the snapshot factory.
    struct Input: Equatable {
        struct PullRequest: Equatable {
            let label: String
            let number: Int
            let status: SidebarPullRequestStatus
            var checks: Checks? = nil
        }

        /// Agent-owned status entries in display order.
        var agentEntries: [SidebarStatusEntry] = []
        /// Lifecycle states of the workspace's agents (manual loaders excluded).
        var lifecycleStates: [AgentHibernationLifecycleState] = []
        /// Whether a coding agent is actively working (the spinner's signal).
        var hasActiveAgent = false
        var pullRequests: [PullRequest] = []
        var branch: String?
        var directory: String?
        /// `sidebar.compactStatusIcons`, already validated.
        var iconOverrides: [String: String] = [:]
    }

    private static let tooltipFormat = String(
        localized: "sidebar.agentStatus.glyph.tooltip",
        defaultValue: "%1$@: %2$@"
    )

    static func resolve(_ input: Input) -> SidebarCompactStatusGlyph {
        let kind: Kind
        if input.agentEntries.contains(where: Self.reportsError) {
            kind = .error
        } else if input.lifecycleStates.contains(.needsInput) {
            kind = .needsInput
        } else if input.hasActiveAgent || input.lifecycleStates.contains(.running) {
            kind = .running
        } else if input.lifecycleStates.contains(.unknown) {
            kind = .pending
        } else if let pullRequest = input.pullRequests.first {
            switch pullRequest.status {
            case .open: kind = .pullRequest(.open(pullRequest.checks))
            case .merged: kind = .pullRequest(.merged)
            case .closed: kind = .pullRequest(.closed)
            }
        } else if input.lifecycleStates.contains(.idle) || !input.agentEntries.isEmpty {
            kind = .idle
        } else if input.branch != nil {
            kind = .branch
        } else {
            kind = .terminal
        }
        return SidebarCompactStatusGlyph(kind: kind, tooltip: tooltip(for: input), iconOverrides: input.iconOverrides)
    }

    /// Agent hooks mark failures with the warning-triangle icon.
    private static func reportsError(_ entry: SidebarStatusEntry) -> Bool {
        entry.icon?.contains("exclamationmark.triangle") == true
    }

    private static func tooltip(for input: Input) -> String {
        var lines = input.agentEntries.map {
            line(agentDisplayName(forStatusKey: $0.key), $0.value)
        }
        // A lifecycle report can arrive before (or without) a status entry;
        // name the state so the tooltip and VoiceOver label are never empty.
        if lines.isEmpty, let state = lifecycleText(input.lifecycleStates) {
            lines.append(state)
        }
        lines += input.pullRequests.map {
            line("\($0.label) #\($0.number)", pullRequestStatusText($0.status))
        }
        if let branch = input.branch {
            lines.append(branch)
        }
        if let directory = input.directory {
            lines.append(directory)
        }
        return lines.joined(separator: "\n")
    }

    private static func line(_ name: String, _ value: String) -> String {
        String(format: tooltipFormat, locale: .current, name, value)
    }

    private static func lifecycleText(_ states: [AgentHibernationLifecycleState]) -> String? {
        if states.contains(.needsInput) {
            return String(localized: "feed.status.needsInput", defaultValue: "Needs input")
        }
        if states.contains(.running) {
            return String(localized: "agent.generic.status.running", defaultValue: "Running")
        }
        if states.contains(.idle) {
            return String(localized: "agentSession.web.status.idle", defaultValue: "Idle")
        }
        return nil
    }

    private static func pullRequestStatusText(_ status: SidebarPullRequestStatus) -> String {
        switch status {
        case .open: return String(localized: "sidebar.pullRequest.statusOpen", defaultValue: "open")
        case .merged: return String(localized: "sidebar.pullRequest.statusMerged", defaultValue: "merged")
        case .closed: return String(localized: "sidebar.pullRequest.statusClosed", defaultValue: "closed")
        }
    }

    /// Splits display-ordered status entries into agent-owned entries (which
    /// compact mode folds into the glyph) and the entries that keep their
    /// metadata rows. With `compacts` off every entry stays a row.
    static func partition(
        _ entries: [SidebarStatusEntry],
        compacts: Bool,
        isAgentKey: (String) -> Bool = AgentHibernationLifecycleStatusKeys.isAllowed
    ) -> (agent: [SidebarStatusEntry], rows: [SidebarStatusEntry]) {
        guard compacts else { return ([], entries) }
        var agent: [SidebarStatusEntry] = []
        var rows: [SidebarStatusEntry] = []
        for entry in entries {
            if isAgentKey(entry.key) {
                agent.append(entry)
            } else {
                rows.append(entry)
            }
        }
        return (agent, rows)
    }

    /// Human name for an agent status key (`claude_code` -> "Claude Code").
    static func agentDisplayName(forStatusKey key: String) -> String {
        if let definition = CmuxTaskManagerCodingAgentDefinition.builtIns.first(where: {
            $0.id == key || $0.directBasenames.contains(key)
        }) {
            return definition.displayName
        }
        return key
            .split(whereSeparator: { $0 == "_" || $0 == "-" })
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }

    /// Selected rows flatten the glyph to the selected foreground, like the
    /// metadata rows do, so colors never vanish into the selection fill.
    func color(isActive: Bool, selected: NSColor, secondary: NSColor) -> NSColor {
        if isActive { return selected }
        switch kind {
        case .error, .pullRequest(.open(.failing)): return .systemRed
        case .needsInput: return .systemYellow
        case .unseen: return .systemBlue
        case .pullRequest(.open(.conflict)): return .systemOrange
        case .pullRequest(.open(.passing)): return .systemGreen
        case .pullRequest(.merged): return .systemPurple
        case .running, .pending, .idle, .branch, .terminal, .pullRequest(.open(nil)), .pullRequest(.closed):
            return secondary
        }
    }
}

/// Draws a compact status glyph in both sidebar engines. The running pulse
/// is a Core Animation opacity loop run by the render server, gated like
/// `GPUSpinnerNSView`: it stops while the view or an ancestor is hidden, the
/// window is occluded, the row is suspended, or Reduce Motion is on; it asks
/// for at most 30 Hz; and every pulsing row shares one phase.
final class SidebarCompactStatusGlyphImageView: NSImageView {
    private static let pulseKey = "cmux.compactStatus.pulse"
    private static let pulseDuration: CFTimeInterval = 0.9
    private var pulses = false

    /// Cleared by a suspended AppKit cell, like the spinner's flag.
    var isPresentationActive = true {
        didSet { if oldValue != isPresentationActive { updatePulse() } }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        imageScaling = .scaleNone
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(visibilityChanged),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    deinit {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        NotificationCenter.default.removeObserver(self)
    }

    func configure(_ glyph: SidebarCompactStatusGlyph, pointSize: CGFloat, color: NSColor) {
        image = Self.image(symbol: glyph.symbolName, badge: glyph.badgeSymbolName, pointSize: pointSize)
            ?? Self.image(symbol: glyph.defaultSymbolName, badge: nil, pointSize: pointSize)
        contentTintColor = color
        toolTip = glyph.tooltip.isEmpty ? nil : glyph.tooltip
        setAccessibilityElement(!glyph.tooltip.isEmpty)
        setAccessibilityLabel(glyph.tooltip)
        setAccessibilityRole(.image)
        if pulses != glyph.pulses {
            pulses = glyph.pulses
            updatePulse()
        }
    }

    private struct ImageKey: Hashable {
        let symbol: String
        let badge: String?
        let pointSize: CGFloat
    }

    @MainActor private static var imageCache: [ImageKey: NSImage] = [:]

    /// The glyph's template image; a badge is knocked out of the base symbol's
    /// lower trailing corner so it reads at sidebar size. Cached per key.
    @MainActor static func image(symbol: String, badge: String?, pointSize: CGFloat) -> NSImage? {
        let key = ImageKey(symbol: symbol, badge: badge, pointSize: pointSize)
        if let cached = imageCache[key] { return cached }
        guard let base = RenderableSystemSymbol.configuredAppKitImage(
            systemName: symbol, pointSize: pointSize, weight: .semibold
        ) else { return nil }
        guard let badge, let badgeImage = RenderableSystemSymbol.configuredAppKitImage(
            systemName: badge, pointSize: pointSize * 0.62, weight: .bold
        ) else {
            imageCache[key] = base
            return base
        }
        let size = base.size
        let composed = NSImage(size: size, flipped: false) { rect in
            base.draw(in: rect)
            let side = min(rect.width, rect.height) * 0.62
            let badgeRect = NSRect(x: rect.maxX - side, y: rect.minY, width: side, height: side)
            guard let context = NSGraphicsContext.current else { return true }
            context.compositingOperation = .destinationOut
            NSColor.black.setFill()
            NSBezierPath(ovalIn: badgeRect.insetBy(dx: -1, dy: -1)).fill()
            context.compositingOperation = .sourceOver
            badgeImage.draw(in: badgeRect)
            return true
        }
        composed.isTemplate = true
        imageCache[key] = composed
        return composed
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(self, name: NSWindow.didChangeOcclusionStateNotification, object: nil)
        if let window {
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(visibilityChanged),
                name: NSWindow.didChangeOcclusionStateNotification,
                object: window
            )
        }
        updatePulse()
    }

    override func viewDidHide() {
        super.viewDidHide()
        updatePulse()
    }

    override func viewDidUnhide() {
        super.viewDidUnhide()
        updatePulse()
    }

    @objc private func visibilityChanged() {
        updatePulse()
    }

    private var shouldPulse: Bool {
        guard pulses, isPresentationActive, !isHiddenOrHasHiddenAncestor else { return false }
        guard let window, window.occlusionState.contains(.visible) else { return false }
        return !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    private func updatePulse() {
        guard let layer else { return }
        guard shouldPulse else {
            layer.removeAnimation(forKey: Self.pulseKey)
            return
        }
        guard layer.animation(forKey: Self.pulseKey) == nil else { return }
        let pulse = CABasicAnimation(keyPath: "opacity")
        pulse.fromValue = 1.0
        pulse.toValue = 0.3
        pulse.duration = Self.pulseDuration
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        pulse.isRemovedOnCompletion = false
        pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        pulse.preferredFrameRateRange = CAFrameRateRange(minimum: 10, maximum: 30, preferred: 30)
        // Anchor to the shared media clock so every pulsing row is in phase.
        let globalNow = CACurrentMediaTime()
        let period = Self.pulseDuration * 2
        pulse.beginTime = layer.convertTime(globalNow, from: nil) - globalNow.truncatingRemainder(dividingBy: period)
        layer.add(pulse, forKey: Self.pulseKey)
    }
}

/// SwiftUI rendering for the default sidebar list. Takes resolved values
/// only; no store access below the lazy-list boundary.
struct SidebarCompactStatusGlyphView: NSViewRepresentable {
    let glyph: SidebarCompactStatusGlyph
    let pointSize: CGFloat
    let color: NSColor

    func makeNSView(context: Context) -> SidebarCompactStatusGlyphImageView {
        SidebarCompactStatusGlyphImageView()
    }

    func updateNSView(_ view: SidebarCompactStatusGlyphImageView, context: Context) {
        view.configure(glyph, pointSize: pointSize, color: color)
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        nsView: SidebarCompactStatusGlyphImageView,
        context: Context
    ) -> CGSize? {
        CGSize(width: pointSize + 4, height: pointSize + 4)
    }
}
