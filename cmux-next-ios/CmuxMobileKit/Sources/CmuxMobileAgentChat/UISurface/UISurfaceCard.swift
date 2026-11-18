#if os(iOS)
import CmuxMobileDesign
import CmuxSpinner
import SwiftUI

/// An agent UI surface (`cmux.ui-surface/1`) as one card in place of its tool row, as the Mac's chat
/// draws it (webviews `uiSurface/UiSurfaceCard.tsx`): its title, the source line naming the server and
/// tool it came from ("claimed" when the person did not connect that server), its nodes drawn with
/// cmux's own views, then, while an action waits, the host-written summary of what Confirm sends and
/// to whom with Confirm and Cancel. Nothing reaches the agent or a tool before Confirm. An MCP App's
/// HTML view is not run on the phone in this prototype: a row says to open it on the Mac.
struct UISurfaceCard: View {
    let surface: UISurface
    let host: UISurfaceHost
    /// The tallest the card drew while streaming: its floor until the surface settles, so the
    /// transcript under it does not jump (DESIGN.md "Streaming and frames").
    @State private var reserved: CGFloat = 0
    private let type = CmuxMobileTheme.standard.type

    var body: some View {
        let pending = host.pending(surface)
        let locked = surface.status != .ready || host.waiting.contains(surface.surfaceId)
        VStack(alignment: .leading, spacing: 12) {
            header
            if surface.frame != nil {
                UISurfaceFrameFallback(resourceURI: surface.source.resourceUri)
            }
            if let root = surface.root {
                UISurfaceNodeView(node: root)
            } else if surface.frame == nil, surface.status == .ready {
                UISurfaceFallbackView(text: UISurfaceText.empty)
            }
            if surface.status == .error {
                Label(surface.error ?? UISurfaceText.failed, systemImage: "exclamationmark.triangle.fill")
                    .font(type.meta)
                    .foregroundStyle(Color.cmuxMobileDanger)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let pending {
                UISurfaceConfirmStrip(surface: surface, pending: pending, host: host)
                    .transition(.opacity)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: surface.status == .streaming ? reserved : nil, alignment: .topLeading)
        .background(Color.cmuxMobileCard, in: .rect(cornerRadius: 20, style: .continuous))
        .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { height in
            reserved = surface.status == .streaming ? max(reserved, height) : 0
        }
        .environment(\.uiSurfaceContext, UISurfaceContext(surface: surface, host: host, locked: locked))
        .animation(.cmuxMobileSmooth.unlessReduceMotion, value: pending?.requestId)
        .onChange(of: surface.status) { _, status in
            // VoiceOver hears a streamed card finish or fail without moving to it.
            switch status {
            case .ready: AccessibilityNotification.Announcement(UISurfaceText.ready(surface.title)).post()
            case .error: AccessibilityNotification.Announcement(surface.error ?? UISurfaceText.failed).post()
            case .streaming: break
            }
        }
        .onChange(of: host.pendingShown) { _, _ in
            if let pending = host.pending(surface) {
                AccessibilityNotification.Announcement(UISurfaceText.confirmAnnouncement(pending.summary)).post()
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(surface.title ?? UISurfaceText.card)
        .accessibilityIdentifier("agentChat.uiSurface")
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                if let title = surface.title, !title.isEmpty {
                    Text(title)
                        .font(type.emptyTitle)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)
                }
                HStack(spacing: 6) {
                    let source = surface.sourceLine
                    if !source.isEmpty {
                        Text(UISurfaceText.from(source))
                            .font(type.meta)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    if surface.source.verified == false {
                        Text(UISurfaceText.claimed)
                            .font(type.meta.weight(.semibold))
                            .foregroundStyle(Color.cmuxMobileWarning)
                            .accessibilityHint(UISurfaceText.claimedHint)
                    }
                }
            }
            Spacer(minLength: 0)
            if surface.status == .streaming {
                CmuxSpinner().controlSize(.small)
                    .accessibilityLabel(UISurfaceText.drawing)
            }
        }
    }
}

/// What a node reads from its card: the surface, where presses go, and whether presses are off
/// (while streaming, on an error, or with an action on its way).
struct UISurfaceContext {
    let surface: UISurface
    let host: UISurfaceHost?
    var locked: Bool
}

extension EnvironmentValues {
    @Entry var uiSurfaceContext: UISurfaceContext?
}

/// The pending action's strip: the host-written summary, what it sends, to whom, then Cancel and
/// Confirm. Return confirms and Escape cancels on a hardware keyboard (DESIGN.md).
struct UISurfaceConfirmStrip: View {
    let surface: UISurface
    let pending: UISurface.Pending
    let host: UISurfaceHost
    private let type = CmuxMobileTheme.standard.type

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(UISurfaceText.confirmTitle, systemImage: "hand.raised.fill")
                .font(type.meta.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(pending.summary)
                .font(type.body)
                .fixedSize(horizontal: false, vertical: true)
            if let sends = pending.sends, !sends.isEmpty {
                UISurfaceFacts(facts: sends.map { UISurface.Fact(label: $0.label, value: $0.value) })
            }
            if let target = pending.target, let line = UISurfaceText.target(target) {
                Text(line)
                    .font(type.meta)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
            }
            HStack(spacing: 8) {
                Button(UISurfaceText.cancel) { host.cancel(surface, pending) }
                    .buttonStyle(CmuxMobileCapsuleButtonStyle(.secondary, size: .compact))
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("agentChat.uiSurface.cancel")
                Button(UISurfaceText.confirm) { host.confirm(surface, pending) }
                    .buttonStyle(CmuxMobileCapsuleButtonStyle(.primary, size: .compact))
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("agentChat.uiSurface.confirm")
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.cmuxMobileFill, in: .rect(cornerRadius: 14, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("agentChat.uiSurface.pending")
    }
}

/// An MCP App's HTML view: the phone does not run it in this prototype (DESIGN.md "Not in the prototype").
struct UISurfaceFrameFallback: View {
    let resourceURI: String?
    private let type = CmuxMobileTheme.standard.type

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "macwindow")
                .font(type.toolRow)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(UISurfaceText.frameTitle).font(type.rowTitle)
                Text(UISurfaceText.frameDetail)
                    .font(type.meta)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let resourceURI, !resourceURI.isEmpty {
                    Text(resourceURI)
                        .font(type.codeBody)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.cmuxMobileFill, in: .rect(cornerRadius: 14, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("agentChat.uiSurface.frame")
    }
}

// MARK: - Wording

/// The card's strings (`mobile.agentChat.uiSurface.*`, Resources/Localizable.xcstrings).
struct UISurfaceText {
    static var card: String { String(localized: "mobile.agentChat.uiSurface.card", defaultValue: "Card from the agent", bundle: .module) }
    static func from(_ source: String) -> String {
        String(localized: "mobile.agentChat.uiSurface.from", defaultValue: "from \(source)", bundle: .module)
    }
    static var claimed: String { String(localized: "mobile.agentChat.uiSurface.claimed", defaultValue: "claimed", bundle: .module) }
    static var claimedHint: String {
        String(localized: "mobile.agentChat.uiSurface.claimedHint",
               defaultValue: "You did not connect this server; the agent names it.", bundle: .module)
    }
    static var drawing: String { String(localized: "mobile.agentChat.uiSurface.drawing", defaultValue: "Drawing…", bundle: .module) }
    static func ready(_ title: String?) -> String {
        let name = title ?? card
        return String(localized: "mobile.agentChat.uiSurface.ready", defaultValue: "\(name) is ready", bundle: .module)
    }
    static var failed: String {
        String(localized: "mobile.agentChat.uiSurface.failed", defaultValue: "This card could not be drawn.", bundle: .module)
    }
    static var empty: String { String(localized: "mobile.agentChat.uiSurface.empty", defaultValue: "Nothing to show", bundle: .module) }
    static var confirmTitle: String {
        String(localized: "mobile.agentChat.uiSurface.confirmTitle", defaultValue: "Confirm to send", bundle: .module)
    }
    static func confirmAnnouncement(_ summary: String) -> String {
        String(localized: "mobile.agentChat.uiSurface.confirmAnnouncement", defaultValue: "Confirm to send: \(summary)", bundle: .module)
    }
    static var confirm: String { String(localized: "mobile.agentChat.uiSurface.confirm", defaultValue: "Confirm", bundle: .module) }
    static var cancel: String { String(localized: "mobile.agentChat.uiSurface.cancel", defaultValue: "Cancel", bundle: .module) }
    /// "To the agent", "Runs the tool NAME", "Opens LINK"; nil for a target it does not know.
    static func target(_ target: String) -> String? {
        if target == "agent" { return String(localized: "mobile.agentChat.uiSurface.toAgent", defaultValue: "To the agent", bundle: .module) }
        if target.hasPrefix("tool:") {
            let tool = String(target.dropFirst(5))
            return String(localized: "mobile.agentChat.uiSurface.toTool", defaultValue: "Runs the tool \(tool)", bundle: .module)
        }
        if target.hasPrefix("link:") {
            let link = String(target.dropFirst(5))
            return String(localized: "mobile.agentChat.uiSurface.toLink", defaultValue: "Opens \(link)", bundle: .module)
        }
        return nil
    }
    static var frameTitle: String { String(localized: "mobile.agentChat.uiSurface.frameTitle", defaultValue: "Interactive app", bundle: .module) }
    static var frameDetail: String {
        String(localized: "mobile.agentChat.uiSurface.frameDetail", defaultValue: "Open this chat on your Mac to use it.", bundle: .module)
    }
    static var approve: String { String(localized: "mobile.agentChat.uiSurface.approve", defaultValue: "Approve", bundle: .module) }
    static var deny: String { String(localized: "mobile.agentChat.uiSurface.deny", defaultValue: "Deny", bundle: .module) }
    static var approved: String { String(localized: "mobile.agentChat.uiSurface.approved", defaultValue: "Approved", bundle: .module) }
    static var denied: String { String(localized: "mobile.agentChat.uiSurface.denied", defaultValue: "Denied", bundle: .module) }
    static var riskHigh: String { String(localized: "mobile.agentChat.uiSurface.riskHigh", defaultValue: "High risk", bundle: .module) }
    static var submit: String { String(localized: "mobile.agentChat.uiSurface.submit", defaultValue: "Submit", bundle: .module) }
    static var sent: String { String(localized: "mobile.agentChat.uiSurface.sent", defaultValue: "Sent", bundle: .module) }
    static func truncated(_ count: Int) -> String {
        String(localized: "mobile.agentChat.uiSurface.truncated", defaultValue: "Showing the first \(count) rows", bundle: .module)
    }
    static var chart: String { String(localized: "mobile.agentChat.uiSurface.chart", defaultValue: "Chart", bundle: .module) }
    static var done: String { String(localized: "mobile.agentChat.uiSurface.done", defaultValue: "Done", bundle: .module) }
    static var failedState: String { String(localized: "mobile.agentChat.uiSurface.failedState", defaultValue: "Failed", bundle: .module) }
    static func cannotShow(_ what: String) -> String {
        String(localized: "mobile.agentChat.uiSurface.cannotShow", defaultValue: "Can't show \(what)", bundle: .module)
    }
}
#endif
