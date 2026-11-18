#if os(iOS)
import CmuxMobileDesign
import SwiftUI
import UIKit

/// One node of a surface, drawn by its type with cmux's own views (DESIGN.md "Nodes"). A type this
/// build does not know draws as a fallback naming it; every string is plain text.
struct UISurfaceNodeView: View {
    let node: UISurface.Node
    private let type = CmuxMobileTheme.standard.type

    var body: some View {
        content.modifier(UISurfaceA11yModifier(node: node))
    }

    @ViewBuilder
    private var content: some View {
        switch node.nodeType {
        case .text:
            UISurfaceTextView(text: node.text ?? "", style: node.style)
        case .stack:
            UISurfaceStackView(horizontal: node.axis == "h", children: node.children ?? [])
        case .card:
            VStack(alignment: .leading, spacing: 10) {
                ForEach(node.children ?? []) { UISurfaceNodeView(node: $0) }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.cmuxMobileFill, in: .rect(cornerRadius: 14, style: .continuous))
        case .list:
            let children = node.children ?? []
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(children.enumerated()), id: \.offset) { index, child in
                    if index > 0 { Divider() }
                    UISurfaceNodeView(node: child).padding(.vertical, 8)
                }
            }
        case .divider:
            Divider()
        case .icon:
            if let symbol = UISurfaceIcon.symbol(node.name) {
                Image(systemName: symbol)
                    .font(type.toolRow)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(node.a11y?.label == nil)
            }
        case .image:
            UISurfaceImageAlt(alt: node.alt ?? "")
        case .button:
            UISurfaceButton(node: node)
        case .field:
            UISurfaceFieldView(node: node)
        case .approval:
            UISurfaceApprovalView(node: node)
        case .review:
            UISurfaceReviewView(node: node)
        case .table:
            UISurfaceTableView(node: node)
        case .chart:
            UISurfaceChartView(node: node)
        case .progress:
            UISurfaceProgressView(node: node)
        case .fallback:
            UISurfaceFallbackView(text: node.text ?? "")
        case nil:
            UISurfaceFallbackView(text: UISurfaceText.cannotShow(node.type))
        }
    }
}

/// A node's `a11y`: its label and description for VoiceOver, hidden when it says so, and a live
/// node's changes announced (`polite` or `assertive`).
struct UISurfaceA11yModifier: ViewModifier {
    let node: UISurface.Node

    func body(content: Content) -> some View {
        let a11y = node.a11y
        if a11y?.hidden == true {
            content.accessibilityHidden(true)
        } else {
            content
                .modifier(UISurfaceLabelModifier(label: a11y?.label, description: a11y?.description))
                .onChange(of: node.announcement) { _, now in
                    guard let live = a11y?.live, !now.isEmpty else { return }
                    // `assertive` interrupts what VoiceOver is saying; `polite` waits its turn.
                    let priority: UIAccessibilityPriority = live == "assertive" ? .high : .default
                    UIAccessibility.post(notification: .announcement,
                                         argument: NSAttributedString(string: now, attributes: [.accessibilitySpeechAnnouncementPriority: priority]))
                }
        }
    }
}

private struct UISurfaceLabelModifier: ViewModifier {
    let label: String?
    let description: String?

    func body(content: Content) -> some View {
        if let label, !label.isEmpty {
            content.accessibilityLabel(label).accessibilityHint(description ?? "")
        } else if let description, !description.isEmpty {
            content.accessibilityHint(description)
        } else {
            content
        }
    }
}

extension UISurface.Node {
    /// What a live node says when it changes: its text, label or title, with its value.
    var announcement: String {
        let head = text ?? label ?? title ?? ""
        switch nodeType {
        case .progress:
            if state == "done" { return "\(head), \(UISurfaceText.done)" }
            if state == "failed" { return "\(head), \(UISurfaceText.failedState)" }
            if let value = value?.numberValue, let max, max > 0 {
                return "\(head), \(Int((value / max * 100).rounded()))%"
            }
            return head
        default:
            return [head, value?.uiSurfaceText ?? ""].filter { !$0.isEmpty }.joined(separator: ", ")
        }
    }
}

// MARK: - Basic nodes

struct UISurfaceTextView: View {
    let text: String
    let style: String?
    private let type = CmuxMobileTheme.standard.type

    var body: some View {
        switch style ?? "body" {
        case "heading":
            Text(text).font(type.emptyTitle).fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
        case "caption":
            Text(text).font(type.meta).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        case "code":
            Text(text).font(type.codeBody).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.cmuxMobileCodeBackground, in: .rect(cornerRadius: 8, style: .continuous))
        default:
            Text(text).font(type.body).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// A row or column of nodes. A row stacks as a column at accessibility text sizes.
struct UISurfaceStackView: View {
    let horizontal: Bool
    let children: [UISurface.Node]
    @Environment(\.dynamicTypeSize) private var textSize

    var body: some View {
        let layout = horizontal && !textSize.isAccessibilitySize
            ? AnyLayout(HStackLayout(alignment: .center, spacing: 8))
            : AnyLayout(VStackLayout(alignment: .leading, spacing: 10))
        layout {
            ForEach(children) { UISurfaceNodeView(node: $0) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The fixed icon set (DESIGN.md `icon`, the Mac's `ICONS`): a name outside it draws nothing.
struct UISurfaceIcon {
    static func symbol(_ name: String?) -> String? {
        guard let name else { return nil }
        return switch name {
        case "check": "checkmark"
        case "close": "xmark"
        case "search": "magnifyingglass"
        case "time", "clock": "clock"
        case "warning", "error": "exclamationmark.triangle"
        case "info": "info.circle"
        case "web", "link": "link"
        case "folder": "folder"
        case "file": "doc"
        case "edit": "pencil"
        case "add": "plus"
        case "image": "photo"
        case "mail": "envelope"
        case "send": "paperplane"
        case "lock": "lock"
        case "play": "play.fill"
        case "stop": "stop.fill"
        default: nil
        }
    }
}

/// An image's alt text in a frame: the prototype fetches nothing (DESIGN.md `image`).
struct UISurfaceImageAlt: View {
    let alt: String
    private let type = CmuxMobileTheme.standard.type

    var body: some View {
        Label(alt.isEmpty ? UISurfaceText.cannotShow("image") : alt, systemImage: "photo")
            .font(type.meta)
            .foregroundStyle(.secondary)
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.secondary.opacity(0.4), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(alt)
            .accessibilityAddTraits(.isImage)
    }
}

/// What could not be drawn, as inert text.
struct UISurfaceFallbackView: View {
    let text: String
    private let type = CmuxMobileTheme.standard.type

    var body: some View {
        Label(text, systemImage: "square.dashed")
            .font(type.meta)
            .foregroundStyle(.secondary)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.secondary.opacity(0.4), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            }
            .accessibilityIdentifier("agentChat.uiSurface.fallback")
    }
}

struct UISurfaceButton: View {
    let node: UISurface.Node
    @Environment(\.uiSurfaceContext) private var context

    var body: some View {
        Button(node.label ?? "") {
            guard let context, let action = node.action else { return }
            context.host?.press(context.surface, action)
        }
        .buttonStyle(CmuxMobileCapsuleButtonStyle(kind, size: .compact))
        .disabled(node.action == nil || context?.locked != false)
        .accessibilityIdentifier("agentChat.uiSurface.button.\(node.id)")
    }

    private var kind: CmuxMobileCapsuleButtonStyle.Kind {
        switch node.variant ?? "secondary" {
        case "primary": .primary
        case "danger": .destructive
        default: .secondary
        }
    }
}

// MARK: - Fields

/// A field (`text`, `checkbox`, `choice`, `slider`, `date`). Its value lives in the chat's
/// ``UISurfaceHost`` under its bind; an edit stays on the phone until a confirmed action sends it.
struct UISurfaceFieldView: View {
    let node: UISurface.Node
    @Environment(\.uiSurfaceContext) private var context
    private let type = CmuxMobileTheme.standard.type

    private var key: String { node.bind ?? node.id }
    private var value: JSONValue? {
        guard let context else { return node.value }
        return context.host?.value(context.surface, key, initial: node.value) ?? node.value
    }

    private func set(_ value: JSONValue) {
        guard let context else { return }
        context.host?.set(context.surface, key, value)
    }

    var body: some View {
        let label = node.label ?? ""
        switch node.input ?? "text" {
        case "checkbox":
            Toggle(isOn: Binding(get: { value == .bool(true) }, set: { set(.bool($0)) })) {
                Text(label).font(type.body)
            }
            .disabled(context?.locked == true)
        case "choice":
            VStack(alignment: .leading, spacing: 6) {
                fieldLabel(label)
                UISurfaceChoice(options: node.options ?? [], multi: node.multi == true, selected: selectedKeys,
                                disabled: context?.locked == true) { set($0) }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(label)
        case "slider":
            sliderField(label)
        case "date":
            DatePicker(selection: Binding(get: { UISurfaceDates.date(value?.stringValue) ?? Date() },
                                          set: { set(.string(UISurfaceDates.string($0))) }),
                       displayedComponents: .date) {
                Text(label).font(type.body)
            }
            .disabled(context?.locked == true)
        default:
            VStack(alignment: .leading, spacing: 6) {
                fieldLabel(label)
                let text = Binding(get: { value?.uiSurfaceText ?? "" }, set: { set(.string($0)) })
                Group {
                    if node.secure == true {
                        SecureField(label, text: text)
                    } else {
                        TextField(label, text: text)
                    }
                }
                    .font(type.body)
                    .padding(.horizontal, 12)
                    .frame(minHeight: 44)
                    .background(Color.cmuxMobileFill, in: .rect(cornerRadius: 10, style: .continuous))
                    .disabled(context?.locked == true)
                    .accessibilityLabel(label)
            }
        }
    }

    private var selectedKeys: [String] {
        switch value {
        case .string(let one)?: [one]
        case .array(let many)?: many.compactMap(\.stringValue)
        default: []
        }
    }

    private func fieldLabel(_ label: String) -> some View {
        Text(label).font(type.meta).foregroundStyle(.secondary).accessibilityHidden(true)
    }

    @ViewBuilder
    private func sliderField(_ label: String) -> some View {
        let low = node.min ?? 0
        let high = Swift.max(node.max ?? 100, low + 1)
        let current = Swift.min(Swift.max(value?.numberValue ?? low, low), high)
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                fieldLabel(label)
                Spacer()
                Text(JSONValue.number(current.rounded()).uiSurfaceText)
                    .font(type.meta.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Slider(value: Binding(get: { current }, set: { set(.number($0.rounded())) }), in: low...high, step: 1)
                .disabled(context?.locked == true)
                .accessibilityLabel(label)
        }
    }
}

/// A choice: chips for up to six options (or any multi choice), else a menu (the Mac's `choiceLook`).
struct UISurfaceChoice: View {
    let options: [UISurface.Option]
    let multi: Bool
    let selected: [String]
    let disabled: Bool
    let choose: (JSONValue) -> Void
    private let type = CmuxMobileTheme.standard.type

    var body: some View {
        if options.count <= 6 || multi {
            UISurfaceFlow(spacing: 8) {
                ForEach(options, id: \.key) { option in
                    let on = selected.contains(option.key)
                    Button {
                        pick(option.key)
                    } label: {
                        Text(option.label)
                            .font(type.chip)
                            .padding(.horizontal, 14)
                            .frame(minHeight: 36)
                    }
                    .buttonStyle(CmuxMobilePressFillStyle(rest: on ? Color.cmuxMobileFillSelected : Color.cmuxMobileFill, cornerRadius: 18))
                    .overlay {
                        if on {
                            RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Color.cmuxMobileAccent, lineWidth: 1.5)
                        }
                    }
                    .padding(.vertical, 4)
                    .contentShape(.rect)
                    .disabled(disabled)
                    .accessibilityAddTraits(on ? .isSelected : [])
                }
            }
        } else {
            Menu {
                ForEach(options, id: \.key) { option in
                    Button(option.label) { pick(option.key) }
                }
            } label: {
                HStack {
                    Text(options.first { selected.contains($0.key) }?.label ?? "—").font(type.body)
                    Spacer()
                    Image(systemName: "chevron.up.chevron.down").foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12)
                .frame(minHeight: 44)
                .background(Color.cmuxMobileFill, in: .rect(cornerRadius: 10, style: .continuous))
            }
            .buttonStyle(.cmuxPressFill)
            .disabled(disabled)
        }
    }

    private func pick(_ key: String) {
        guard multi else {
            choose(.string(key))
            return
        }
        var keys = selected
        if let index = keys.firstIndex(of: key) { keys.remove(at: index) } else { keys.append(key) }
        choose(.array(keys.map(JSONValue.string)))
    }
}

/// Dates as fields hold them: `yyyy-MM-dd` in the phone's time zone.
struct UISurfaceDates {
    private static var style: Date.ISO8601FormatStyle { Date.ISO8601FormatStyle(timeZone: .current).year().month().day() }

    static func date(_ text: String?) -> Date? {
        guard let text, !text.isEmpty else { return nil }
        return try? style.parse(String(text.prefix(10)))
    }

    static func string(_ date: Date) -> String { date.formatted(style) }
}

/// Lays its subviews out in rows, wrapping to the next row when one does not fit.
struct UISurfaceFlow: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) -> CGSize {
        let width = proposal.width ?? .infinity
        let rows = rows(width: width, subviews: subviews)
        let height = rows.reduce(CGFloat(0)) { $0 + $1.height } + spacing * CGFloat(Swift.max(rows.count - 1, 0))
        let widest = rows.map(\.width).max() ?? 0
        return CGSize(width: width.isFinite ? width : widest, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) {
        var y = bounds.minY
        for row in rows(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(width: Swift.min(size.width, bounds.width), height: size.height))
                x += Swift.min(size.width, bounds.width) + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func rows(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = []
        var row = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let itemWidth = Swift.min(size.width, width)
            if !row.indices.isEmpty, row.width + spacing + itemWidth > width {
                rows.append(row)
                row = Row()
            }
            row.width += (row.indices.isEmpty ? 0 : spacing) + itemWidth
            row.height = Swift.max(row.height, size.height)
            row.indices.append(index)
        }
        if !row.indices.isEmpty { rows.append(row) }
        return rows
    }
}
#endif
