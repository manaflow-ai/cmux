#if os(iOS)
import Charts
import CmuxMobileDesign
import CmuxSpinner
import SwiftUI

// The cmux catalog's nodes (`ApprovalCard`, `ReviewCard`, `Table`, `Chart`, `Progress`), each in the
// look the Mac's `uiSurface/looks.ts` picks from its data: an approval compact, full or danger; a
// review as chips, a list or a ranked list.

/// Label and value pairs (an approval's facts, a pending action's sends).
struct UISurfaceFacts: View {
    let facts: [UISurface.Fact]
    @Environment(\.dynamicTypeSize) private var textSize
    private let type = CmuxMobileTheme.standard.type

    var body: some View {
        if textSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(facts.enumerated()), id: \.offset) { _, fact in
                    VStack(alignment: .leading, spacing: 0) {
                        Text(fact.label).font(type.meta).foregroundStyle(.secondary)
                        Text(fact.value).font(type.rowSubtitle).fixedSize(horizontal: false, vertical: true)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        } else {
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 4) {
                ForEach(Array(facts.enumerated()), id: \.offset) { _, fact in
                    GridRow {
                        Text(fact.label).font(type.meta).foregroundStyle(.secondary)
                        Text(fact.value).font(type.rowSubtitle).fixedSize(horizontal: false, vertical: true)
                            .accessibilityLabel("\(fact.label): \(fact.value)")
                    }
                }
            }
        }
    }
}

// MARK: - Approval

/// An approval: title, detail and facts, then Deny and Approve. Each answer is an action like any
/// other: a tap opens the confirm strip, Confirm sends it (DESIGN.md).
struct UISurfaceApprovalView: View {
    let node: UISurface.Node
    @Environment(\.uiSurfaceContext) private var context
    private let type = CmuxMobileTheme.standard.type

    var body: some View {
        let danger = node.risk == "high"
        let answered = context.flatMap { $0.host?.confirmed[$0.surface.surfaceId] } ?? []
        let approved = node.approve.map { answered.contains($0.id) } ?? false
        let denied = node.deny.map { answered.contains($0.id) } ?? false
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: danger ? "exclamationmark.triangle.fill" : "hand.raised.fill")
                    .foregroundStyle(danger ? Color.cmuxMobileDanger : node.risk == "medium" ? Color.cmuxMobileWarning : Color.secondary)
                    .accessibilityHidden(true)
                Text(node.title ?? "")
                    .font(type.emptyTitle)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 0)
                if danger {
                    Text(UISurfaceText.riskHigh)
                        .font(type.meta.weight(.semibold))
                        .foregroundStyle(Color.cmuxMobileDanger)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(Color.cmuxMobileDanger.opacity(0.14), in: Capsule())
                }
            }
            if let detail = node.detail, !detail.isEmpty {
                Text(detail).font(type.body).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if let facts = node.facts, !facts.isEmpty {
                UISurfaceFacts(facts: facts)
            }
            if approved || denied {
                Label(approved ? UISurfaceText.approved : UISurfaceText.denied, systemImage: approved ? "checkmark.circle" : "xmark.circle")
                    .font(type.toolRow)
                    .foregroundStyle(.secondary)
            } else {
                HStack(spacing: 8) {
                    if let deny = node.deny {
                        Button(UISurfaceText.deny) { press(deny) }
                            .buttonStyle(CmuxMobileCapsuleButtonStyle(.secondary, size: .compact))
                            .accessibilityIdentifier("agentChat.uiSurface.deny")
                    }
                    if let approve = node.approve {
                        Button(UISurfaceText.approve) { press(approve) }
                            .buttonStyle(CmuxMobileCapsuleButtonStyle(danger ? .destructive : .primary, size: .compact))
                            .accessibilityIdentifier("agentChat.uiSurface.approve")
                    }
                }
                .disabled(context?.locked != false)
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func press(_ action: UISurface.Action) {
        guard let context else { return }
        context.host?.press(context.surface, action)
    }
}

// MARK: - Review

/// A review: a prompt and options to pick (one, or several with `multi`), then Submit.
struct UISurfaceReviewView: View {
    let node: UISurface.Node
    @Environment(\.uiSurfaceContext) private var context
    private let type = CmuxMobileTheme.standard.type

    private enum Look { case chips, list, ranked }

    /// The Mac's `reviewLook`: short labels with no details are chips; more than four detailed
    /// options are a ranked list; else a list.
    private var look: Look {
        let options = node.options ?? []
        let details = options.contains { $0.detail?.isEmpty == false }
        if !details, options.allSatisfy({ $0.label.count <= 24 }) { return .chips }
        return details && options.count > 4 ? .ranked : .list
    }

    private var key: String { node.bind ?? node.id }

    private var selected: [String] {
        guard let context else { return [] }
        switch context.host?.value(context.surface, key, initial: node.value) {
        case .string(let one)?: return [one]
        case .array(let many)?: return many.compactMap(\.stringValue)
        default: return []
        }
    }

    var body: some View {
        let locked = context?.locked != false
        let sent = node.submit.map { action in
            context.flatMap { $0.host?.confirmed[$0.surface.surfaceId]?.contains(action.id) } ?? false
        } ?? false
        VStack(alignment: .leading, spacing: 10) {
            if let title = node.title, !title.isEmpty {
                Text(title).font(type.emptyTitle).fixedSize(horizontal: false, vertical: true).accessibilityAddTraits(.isHeader)
            }
            if let prompt = node.prompt, !prompt.isEmpty {
                Text(prompt).font(type.body).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            switch look {
            case .chips:
                UISurfaceChoice(options: node.options ?? [], multi: node.multi == true, selected: selected, disabled: locked || sent) { set($0) }
            case .list, .ranked:
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array((node.options ?? []).enumerated()), id: \.offset) { index, option in
                        row(option, rank: look == .ranked ? index + 1 : nil, disabled: locked || sent)
                    }
                }
            }
            if sent {
                Label(UISurfaceText.sent, systemImage: "checkmark.circle").font(type.toolRow).foregroundStyle(.secondary)
            } else if let submit = node.submit {
                Button(UISurfaceText.submit) {
                    guard let context else { return }
                    context.host?.press(context.surface, submit)
                }
                .buttonStyle(CmuxMobileCapsuleButtonStyle(.primary, size: .compact))
                .disabled(locked || selected.isEmpty)
                .accessibilityIdentifier("agentChat.uiSurface.submit")
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func row(_ option: UISurface.Option, rank: Int?, disabled: Bool) -> some View {
        let on = selected.contains(option.key)
        let multi = node.multi == true
        return Button {
            pick(option.key)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                if let rank {
                    Text("\(rank)").font(type.meta.monospacedDigit()).foregroundStyle(.secondary).frame(minWidth: 16)
                }
                Image(systemName: multi ? (on ? "checkmark.square.fill" : "square") : (on ? "largecircle.fill.circle" : "circle"))
                    .foregroundStyle(on ? Color.cmuxMobileAccent : Color.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(option.label).font(type.rowTitle).fixedSize(horizontal: false, vertical: true)
                    if let detail = option.detail, !detail.isEmpty {
                        Text(detail).font(type.meta).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(minHeight: 44)
            .contentShape(.rect)
        }
        .buttonStyle(CmuxMobilePressFillStyle(rest: on ? Color.cmuxMobileFillSelected : nil, cornerRadius: 10))
        .disabled(disabled)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    private func pick(_ optionKey: String) {
        guard node.multi == true else {
            set(.string(optionKey))
            return
        }
        var keys = selected
        if let index = keys.firstIndex(of: optionKey) { keys.remove(at: index) } else { keys.append(optionKey) }
        set(.array(keys.map(JSONValue.string)))
    }

    private func set(_ value: JSONValue) {
        guard let context else { return }
        context.host?.set(context.surface, key, value)
    }
}

// MARK: - Table

/// A table that scrolls sideways when it is wider than the card (rows capped at 200 by Rust).
struct UISurfaceTableView: View {
    let node: UISurface.Node
    private let type = CmuxMobileTheme.standard.type

    var body: some View {
        let columns = node.columns ?? []
        let rows = node.rows ?? []
        VStack(alignment: .leading, spacing: 6) {
            ScrollView(.horizontal) {
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 16, verticalSpacing: 8) {
                    GridRow {
                        ForEach(Array(columns.enumerated()), id: \.offset) { _, column in
                            Text(column.label)
                                .font(type.meta.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .gridColumnAlignment(Self.alignment(column.align))
                                .accessibilityAddTraits(.isHeader)
                        }
                    }
                    Divider()
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                        GridRow {
                            ForEach(Array(columns.enumerated()), id: \.offset) { index, column in
                                let cell = index < row.count ? row[index] : ""
                                Text(cell)
                                    .font(type.rowSubtitle)
                                    .lineLimit(3)
                                    .frame(maxWidth: 280, alignment: Self.frameAlignment(column.align))
                                    .accessibilityLabel("\(column.label): \(cell)")
                            }
                        }
                    }
                }
                .padding(.vertical, 4)
            }
            .accessibilityIdentifier("agentChat.uiSurface.table")
            if node.truncated == true {
                Text(UISurfaceText.truncated(rows.count)).font(type.meta).foregroundStyle(.tertiary)
            }
        }
    }

    static func alignment(_ align: String?) -> HorizontalAlignment {
        switch align ?? "left" {
        case "right", "end": .trailing
        case "center": .center
        default: .leading
        }
    }

    static func frameAlignment(_ align: String?) -> Alignment {
        switch align ?? "left" {
        case "right", "end": .trailing
        case "center": .center
        default: .leading
        }
    }
}

// MARK: - Chart

/// A bar, line or pie chart (Swift Charts). A pie draws its first series, as on the Mac.
struct UISurfaceChartView: View {
    let node: UISurface.Node
    @Environment(\.dynamicTypeSize) private var textSize

    private var yLabel: String { node.yLabel ?? "y" }

    var body: some View {
        chart
            .frame(height: textSize.isAccessibilitySize ? 280 : 200)
            .accessibilityLabel(node.a11y?.label ?? node.yLabel ?? UISurfaceText.chart)
            .accessibilityIdentifier("agentChat.uiSurface.chart")
    }

    @ViewBuilder
    private var chart: some View {
        let series = node.series ?? []
        switch node.kind ?? "bar" {
        case "pie":
            let points = series.first?.points ?? []
            Chart(Array(points.enumerated()), id: \.offset) { _, point in
                SectorMark(angle: .value(yLabel, point.y), innerRadius: .ratio(0.5), angularInset: 1)
                    .foregroundStyle(by: .value("x", point.x))
            }
        case "line":
            Chart {
                ForEach(Array(series.enumerated()), id: \.offset) { _, entry in
                    ForEach(Array(entry.points.enumerated()), id: \.offset) { _, point in
                        LineMark(x: .value("x", point.x), y: .value(yLabel, point.y))
                            .foregroundStyle(by: .value("series", entry.name))
                        PointMark(x: .value("x", point.x), y: .value(yLabel, point.y))
                            .foregroundStyle(by: .value("series", entry.name))
                    }
                }
            }
            .chartYAxisLabel { Text(yLabel) }
        default:
            Chart {
                ForEach(Array(series.enumerated()), id: \.offset) { _, entry in
                    ForEach(Array(entry.points.enumerated()), id: \.offset) { _, point in
                        BarMark(x: .value("x", point.x), y: .value(yLabel, point.y))
                            .foregroundStyle(by: .value("series", entry.name))
                            .position(by: .value("series", entry.name))
                    }
                }
            }
            .chartYAxisLabel { Text(yLabel) }
        }
    }
}

// MARK: - Progress

/// Progress: a spinner while running with no value, a bar with its percent when it has one, and a
/// mark when done or failed. `max` is 100 when absent, as on the Mac.
struct UISurfaceProgressView: View {
    let node: UISurface.Node
    private let type = CmuxMobileTheme.standard.type

    var body: some View {
        let state = node.state ?? "running"
        let total = (node.max ?? 100) > 0 ? (node.max ?? 100) : 1
        let value = node.value?.numberValue
        let ratio = value.map { Swift.min(Swift.max($0 / total, 0), 1) }
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 8) {
                switch state {
                case "done":
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.cmuxMobileSuccess)
                case "failed":
                    Image(systemName: "xmark.octagon.fill").foregroundStyle(Color.cmuxMobileDanger)
                default:
                    CmuxSpinner().controlSize(.small)
                }
                Text(node.label ?? "").font(type.rowTitle).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                if let ratio {
                    Text("\(Int((ratio * 100).rounded()))%")
                        .font(type.meta.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .contentTransition(.numericText())
                }
            }
            if let ratio {
                ProgressView(value: ratio)
                    .tint(state == "failed" ? Color.cmuxMobileDanger : state == "done" ? Color.cmuxMobileSuccess : Color.cmuxMobileAccent)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(node.label ?? "")
        .accessibilityValue(accessibilityValue(state: state, ratio: ratio))
        .accessibilityIdentifier("agentChat.uiSurface.progress")
    }

    private func accessibilityValue(state: String, ratio: Double?) -> String {
        if state == "done" { return UISurfaceText.done }
        if state == "failed" { return UISurfaceText.failedState }
        return ratio.map { "\(Int(($0 * 100).rounded()))%" } ?? ""
    }
}
#endif
