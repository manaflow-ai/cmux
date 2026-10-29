import AppKit
import CmuxNextDesign
import Observation
import SwiftUI

/// The chat's Session Info, drawn by the App (``AgentPaneSessionInfo``): the shared overlay glass
/// floating over the agent pane at its right, from under the header to the pane's foot (Leo,
/// 2026-10-26: "you still haven't done the full-length thing"). It floats: it never takes a column
/// and never moves the chat's layout; the page shifts the chat left only when both fit
/// (design/session-info.md rule 2, `inspectorChatShift`). No close button and no band at its top:
/// its header toggle and Esc close it. Its left edge drags its width.
final class AgentPaneSessionInfoPanel: NSView {
    let store: AgentPaneSessionInfoStore
    private let glass: OverlaySurfaceView
    private let edge = AgentPaneSessionInfoEdge()

    init(store: AgentPaneSessionInfoStore) {
        self.store = store
        let content = NSHostingView(rootView: AgentPaneSessionInfoContent(store: store))
        content.sizingOptions = []
        glass = Glass.makeOverlayPanel(content: content)
        super.init(frame: .zero)
        glass.translatesAutoresizingMaskIntoConstraints = true
        glass.autoresizingMask = [.width, .height]
        addSubview(glass)
        edge.autoresizingMask = [.height, .maxXMargin]
        addSubview(edge)
        edge.onDrag = { [weak self] delta, ended in self?.store.drag(by: delta, ended: ended) }
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        glass.frame = bounds
        edge.frame = CGRect(x: 0, y: 0, width: AgentPaneSessionInfoEdge.width, height: bounds.height)
    }

    /// Esc from inside the panel closes it, as the page's did.
    override func cancelOperation(_ sender: Any?) { store.act("close") }
}

/// What the panel draws and how its clicks reach the page.
@MainActor @Observable final class AgentPaneSessionInfoStore {
    var info: AgentPaneSessionInfoModel?
    var colors = AgentPaneSessionInfoColors()
    /// Points per CSS pixel: the page's zoom.
    var zoom: CGFloat = 1
    /// The width a drag of the left edge gives the panel before the page hears it, CSS pixels.
    var dragWidth: Double?
    /// Sends a row's, a button's or the panel's own action id to the page.
    @ObservationIgnored var send: (String) -> Void = { _ in }
    /// The panel's frame needs laying out again (a drag step).
    @ObservationIgnored var relayout: () -> Void = {}

    /// The panel's width in CSS pixels: the drag's while one runs, else the page's.
    var width: Double { dragWidth ?? info?.width ?? 0 }

    func act(_ id: String) { send(id) }

    /// The left edge moved `delta` points (positive: right, narrower); at the end the page keeps the
    /// width (its `INSPECTOR_WIDTH` bounds it).
    func drag(by delta: CGFloat, ended: Bool) {
        guard let info else { return }
        let next = min(560, max(260, (dragWidth ?? info.width) - Double(delta / max(0.25, zoom))))
        dragWidth = next
        relayout()
        guard ended else { return }
        send("width:\(Int(next.rounded()))")
    }

    /// The page answered with its width: the drag is over.
    func update(_ next: AgentPaneSessionInfoModel?) {
        if let next, let dragWidth, abs(next.width - dragWidth) < 1 { self.dragWidth = nil }
        if next == nil { dragWidth = nil }
        info = next
    }
}

/// The pane's theme colors, resolved by the view from its tokens.
struct AgentPaneSessionInfoColors: Equatable {
    var primary = Color(nsColor: ThemeTokens.unresolved.textPrimary.nsColor)
    var secondary = Color(nsColor: ThemeTokens.unresolved.textSecondary.nsColor)
    var tertiary = Color(nsColor: ThemeTokens.unresolved.textTertiary.nsColor)
    var hover = Color(nsColor: ThemeTokens.unresolved.hoverFill.nsColor)
    var separator = Color(nsColor: ThemeTokens.unresolved.separator.nsColor)
    var danger = Color(nsColor: ThemeTokens.unresolved.danger.nsColor)
    var success = Color(nsColor: ThemeTokens.unresolved.success.nsColor)
    var attention = Color(nsColor: ThemeTokens.unresolved.attention.nsColor)
    var accent = Color(nsColor: ThemeTokens.unresolved.litGlyph.nsColor)

    init() {}

    init(_ tokens: ThemeTokens) {
        primary = Color(nsColor: tokens.textPrimary.nsColor)
        secondary = Color(nsColor: tokens.textSecondary.nsColor)
        tertiary = Color(nsColor: tokens.textTertiary.nsColor)
        hover = Color(nsColor: tokens.hoverFill.nsColor)
        separator = Color(nsColor: Borders.color(tokens.separator.nsColor))
        danger = Color(nsColor: tokens.danger.nsColor)
        success = Color(nsColor: tokens.success.nsColor)
        attention = Color(nsColor: tokens.attention.nsColor)
        accent = Color(nsColor: tokens.litGlyph.nsColor)
    }

    func tone(_ tone: AgentPaneSessionInfoModel.Tone?) -> Color {
        switch tone {
        case .failed: danger
        case .waiting: attention
        case .accent: accent
        case .muted, .done: tertiary
        case .running, nil: secondary
        }
    }
}

/// The panel's left edge: a resize cursor and a horizontal drag.
final class AgentPaneSessionInfoEdge: NSView {
    static let width: CGFloat = 6
    var onDrag: ((CGFloat, Bool) -> Void)?
    private var last: CGFloat?

    override func resetCursorRects() { addCursorRect(bounds, cursor: .resizeLeftRight) }
    override func mouseDown(with event: NSEvent) { last = event.locationInWindow.x }
    override func mouseDragged(with event: NSEvent) { step(event, ended: false) }
    override func mouseUp(with event: NSEvent) { step(event, ended: true) }

    private func step(_ event: NSEvent, ended: Bool) {
        guard let start = last else { return }
        let x = event.locationInWindow.x
        last = ended ? nil : x
        onDrag?(x - start, ended)
    }
}

// MARK: - Content

/// What a section or row needs from the panel: its colors and how a click reaches the page. A value,
/// not the store, so a row draws again only when its own values change.
private struct SessionInfoInk {
    let colors: AgentPaneSessionInfoColors
    let act: (String) -> Void
}

private enum SessionInfoMetrics {
    static let inset: CGFloat = 10
    static let rowHeight: CGFloat = 26
    static let rowRadius: CGFloat = 6
    static let indent: CGFloat = 14
    static let glyph: CGFloat = 14
    static let groupGap: CGFloat = 8
}

struct AgentPaneSessionInfoContent: View {
    let store: AgentPaneSessionInfoStore

    var body: some View {
        let colors = store.colors
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 0) {
                if let title = store.info?.title {
                    Text(title)
                        .font(Font(Typography.bodyEmphasized))
                        .foregroundStyle(colors.primary)
                        .lineLimit(1)
                        .padding(.horizontal, SessionInfoMetrics.inset)
                        .padding(.vertical, 8)
                }
                ForEach(Array(groups.enumerated()), id: \.element.id) { index, group in
                    if index > 0 {
                        Rectangle().fill(colors.separator).frame(height: 1)
                            .padding(.horizontal, SessionInfoMetrics.inset)
                            .padding(.vertical, SessionInfoMetrics.groupGap)
                    }
                    ForEach(group.sections) { section in
                        SessionInfoSectionView(section: section, ink: SessionInfoInk(colors: colors, act: store.act))
                    }
                }
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .thinScrollers()
        }
        .scrollIndicators(.automatic)
    }

    private struct Group: Identifiable {
        let id: String
        let sections: [AgentPaneSessionInfoModel.Section]
    }

    /// The sections in the page's order, one block per group (where it runs, what it made, what it runs).
    private var groups: [Group] {
        var result: [Group] = []
        for section in store.info?.sections ?? [] {
            if let last = result.last, last.id == section.group {
                result[result.count - 1] = Group(id: last.id, sections: last.sections + [section])
            } else {
                result.append(Group(id: section.group, sections: [section]))
            }
        }
        return result
    }
}

private struct SessionInfoSectionView: View {
    let section: AgentPaneSessionInfoModel.Section
    let ink: SessionInfoInk

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if section.bare != true { header }
            if section.open || section.bare == true {
                ForEach(section.rows) { row in SessionInfoRowView(row: row, ink: ink) }
                if let more = section.more {
                    SessionInfoHoverRow(ink: ink, action: more.action, help: nil) {
                        Text(more.label)
                            .font(Font(Typography.caption))
                            .foregroundStyle(ink.colors.secondary)
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(section.title)
    }

    private var header: some View {
        let colors = ink.colors
        let fold = section.foldable ? "fold:\(section.id):\(section.open ? 0 : 1)" : nil
        return SessionInfoHoverRow(ink: ink, action: fold, help: nil) {
            HStack(spacing: 6) {
                if let symbol = section.symbol {
                    Image(systemName: symbol)
                        .font(Font(Typography.body))
                        .foregroundStyle(colors.secondary)
                        .frame(width: SessionInfoMetrics.glyph)
                }
                Text(section.title)
                    .font(Font(Typography.header))
                    .foregroundStyle(colors.primary)
                    .lineLimit(1)
                if section.foldable {
                    Image(systemName: section.open ? "chevron.down" : "chevron.right")
                        .font(Font(Typography.caption))
                        .foregroundStyle(colors.tertiary)
                }
                Spacer(minLength: 8)
                if let meta = section.meta {
                    Text(meta)
                        .font(Font(Typography.caption))
                        .foregroundStyle(colors.tone(section.metaTone))
                        .lineLimit(1)
                }
                if let meter = section.meter { SessionInfoMeter(value: meter, colors: colors).frame(width: 36) }
            }
        }
        .accessibilityAddTraits(section.foldable && section.open ? .isSelected : [])
    }
}

private struct SessionInfoRowView: View {
    let row: AgentPaneSessionInfoModel.Row
    let ink: SessionInfoInk

    var body: some View {
        let colors = ink.colors
        SessionInfoHoverRow(ink: ink, action: row.action, help: row.help) {
            HStack(alignment: .center, spacing: 6) {
                glyph
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 4) {
                        Text(row.title)
                            .font(Font(Typography.body))
                            .foregroundStyle(row.tone == .failed ? colors.danger : colors.primary)
                            .lineLimit(1)
                            .layoutPriority(1)
                        if let detail = row.detail {
                            Text(detail)
                                .font(Font(Typography.body))
                                .foregroundStyle(colors.tertiary)
                                .lineLimit(1)
                        }
                    }
                    if let subtitle = row.subtitle {
                        Text(subtitle)
                            .font(Font(Typography.caption))
                            .foregroundStyle(colors.secondary)
                            .lineLimit(2)
                    }
                    if let meter = row.meter { SessionInfoMeter(value: meter, colors: colors) }
                }
                Spacer(minLength: 6)
                if let trailing = row.trailing {
                    Text(trailing)
                        .font(Font(Typography.caption))
                        .monospacedDigit()
                        .foregroundStyle(colors.tone(row.tone))
                        .lineLimit(1)
                }
                ForEach(Array((row.buttons ?? []).enumerated()), id: \.offset) { _, button in
                    SessionInfoButton(button: button, ink: ink)
                }
            }
            .padding(.leading, CGFloat(min(3, max(0, row.indent ?? 0))) * SessionInfoMetrics.indent)
        }
    }

    @ViewBuilder private var glyph: some View {
        if row.tone == .running {
            ThemedSpinner(size: 10).frame(width: SessionInfoMetrics.glyph)
        } else if let symbol = row.symbol {
            Image(systemName: symbol)
                .font(Font(Typography.body))
                .foregroundStyle(row.tone == .failed ? ink.colors.danger : ink.colors.secondary)
                .frame(width: SessionInfoMetrics.glyph)
        }
    }
}

/// A row that lights on hover (the row only, never the panel) and runs `action` on a click.
private struct SessionInfoHoverRow<Label: View>: View {
    let ink: SessionInfoInk
    let action: String?
    let help: String?
    @ViewBuilder let label: () -> Label
    @State private var hovered = false

    var body: some View {
        label()
            .padding(.horizontal, SessionInfoMetrics.inset - 4)
            .frame(maxWidth: .infinity, minHeight: SessionInfoMetrics.rowHeight, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: SessionInfoMetrics.rowRadius)
                    .fill(hovered && action != nil ? ink.colors.hover : .clear)
            )
            .contentShape(Rectangle())
            .onHover { hovered = $0 }
            .onTapGesture { if let action { ink.act(action) } }
            .help(help ?? "")
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(action != nil ? .isButton : [])
            .accessibilityAction { if let action { ink.act(action) } }
    }
}

private struct SessionInfoButton: View {
    let button: AgentPaneSessionInfoModel.Button
    let ink: SessionInfoInk
    @State private var hovered = false

    var body: some View {
        let enabled = button.disabled != true
        Button { if enabled { ink.act(button.action) } } label: {
            Group {
                if let symbol = button.symbol {
                    Image(systemName: symbol).font(Font(Typography.caption))
                } else {
                    Text(button.label).font(Font(Typography.caption))
                }
            }
            .foregroundStyle(enabled ? ink.colors.secondary : ink.colors.tertiary)
            .padding(.horizontal, 5)
            .frame(minWidth: 18, minHeight: 18)
            .background(RoundedRectangle(cornerRadius: 4).fill(hovered && enabled ? ink.colors.hover : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .onHover { hovered = $0 }
        .help(button.label)
        .accessibilityLabel(button.label)
    }
}

private struct SessionInfoMeter: View {
    let value: Double
    let colors: AgentPaneSessionInfoColors

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(colors.hover)
                Capsule().fill(colors.secondary).frame(width: proxy.size.width * min(1, max(0, value)))
            }
        }
        .frame(height: 3)
    }
}
