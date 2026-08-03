import SwiftUI

struct LayoutRootView: View {
    let model: FrontendModel
    let snapshot: ResourceSnapshot
    let screen: ScreenSnapshot

    var body: some View {
        if let zoomed = screen.layout.zoomedPaneID {
            PaneView(model: model, snapshot: snapshot, paneID: zoomed)
                .padding(6)
        } else {
            switch screen.layout.root {
            case .viewport(let baseWidth, let columns):
                ViewportColumnsView(
                    model: model,
                    snapshot: snapshot,
                    baseWidth: baseWidth,
                    columns: columns
                )
            case let root:
                LayoutNodeView(model: model, snapshot: snapshot, node: root)
                    .padding(6)
            }
        }
    }
}

struct ViewportColumnsView: View {
    let model: FrontendModel
    let snapshot: ResourceSnapshot
    let baseWidth: Double
    let columns: [ViewportColumn]

    @State private var pendingWidths: [String: CGFloat] = [:]

    var body: some View {
        GeometryReader { geometry in
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(columns) { column in
                        let naturalWidth = max(
                            360,
                            geometry.size.width * max(0.25, column.width)
                        )
                        let renderedWidth = pendingWidths[column.id] ?? naturalWidth
                        VStack(spacing: 0) {
                            HStack(spacing: 6) {
                                Image(systemName: "rectangle.portrait")
                                Text(column.columnID.suffix(6))
                                    .font(.system(.caption2, design: .monospaced))
                                Spacer()
                                Text("\(Int(column.width * 100))%")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 8)
                            .frame(height: 24)
                            .background(.bar)
                            LayoutNodeView(
                                model: model,
                                snapshot: snapshot,
                                node: column.root
                            )
                            .padding(4)
                        }
                        .frame(
                            width: renderedWidth,
                            height: max(1, geometry.size.height - 12)
                        )
                        .background(Color(nsColor: .controlBackgroundColor).opacity(0.45))
                        .clipShape(.rect(cornerRadius: 8))
                        .overlay {
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(.separator.opacity(0.7), lineWidth: 1)
                        }
                        .overlay(alignment: .trailing) {
                            Rectangle()
                                .fill(.clear)
                                .frame(width: 8)
                                .contentShape(.rect)
                                .gesture(
                                    DragGesture(minimumDistance: 1)
                                        .onChanged { value in
                                            pendingWidths[column.id] = max(
                                                240,
                                                naturalWidth + value.translation.width
                                            )
                                        }
                                        .onEnded { value in
                                            let width = max(
                                                240,
                                                naturalWidth + value.translation.width
                                            )
                                            pendingWidths[column.id] = nil
                                            if let paneID = column.root.paneIDs.first {
                                                model.setViewportWidth(
                                                    paneID: paneID,
                                                    columns: Int(width / 8.4)
                                                )
                                            }
                                        }
                                )
                        }
                    }
                }
                .padding(6)
            }
            .scrollIndicators(.visible)
        }
        .accessibilityValue(L10n.format("column.base_width", "base width %.2f", baseWidth))
    }
}

struct LayoutNodeView: View {
    let model: FrontendModel
    let snapshot: ResourceSnapshot
    let node: LayoutNode

    var body: some View {
        rendered
    }

    private var rendered: AnyView {
        switch node {
        case .leaf(let paneID, _, _):
            return AnyView(PaneView(model: model, snapshot: snapshot, paneID: paneID))
        case .split(let splitID, let direction, let ratio, let first, let second):
            return AnyView(
                SplitLayoutView(
                    model: model,
                    snapshot: snapshot,
                    splitID: splitID,
                    direction: direction,
                    ratio: ratio,
                    first: first,
                    second: second
                )
            )
        case .stack(let paneIDs, let expandedPaneID):
            return AnyView(
                StackLayoutView(
                    model: model,
                    snapshot: snapshot,
                    paneIDs: paneIDs,
                    expandedPaneID: expandedPaneID
                )
            )
        case .viewport(let baseWidth, let columns):
            return AnyView(
                ViewportColumnsView(
                    model: model,
                    snapshot: snapshot,
                    baseWidth: baseWidth,
                    columns: columns
                )
            )
        }
    }
}

private struct SplitLayoutView: View {
    let model: FrontendModel
    let snapshot: ResourceSnapshot
    let splitID: String
    let direction: LayoutNode.SplitDirection
    let ratio: Double
    let first: LayoutNode
    let second: LayoutNode

    @State private var pendingRatio: Double?

    private var safeRatio: CGFloat {
        CGFloat(min(0.85, max(0.15, pendingRatio ?? ratio)))
    }

    var body: some View {
        GeometryReader { geometry in
            if direction == .horizontal {
                HStack(spacing: 5) {
                    LayoutNodeView(model: model, snapshot: snapshot, node: first)
                        .frame(width: max(80, geometry.size.width * safeRatio - 3))
                    splitDivider(total: geometry.size.width)
                    LayoutNodeView(model: model, snapshot: snapshot, node: second)
                }
            } else {
                VStack(spacing: 5) {
                    LayoutNodeView(model: model, snapshot: snapshot, node: first)
                        .frame(height: max(80, geometry.size.height * safeRatio - 3))
                    splitDivider(total: geometry.size.height)
                    LayoutNodeView(model: model, snapshot: snapshot, node: second)
                }
            }
        }
    }

    private func splitDivider(total: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 1)
            .fill(.separator)
            .frame(
                width: direction == .horizontal ? 1 : nil,
                height: direction == .vertical ? 1 : nil
            )
            .contentShape(.rect.inset(by: -4))
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        let delta = direction == .horizontal
                            ? value.translation.width
                            : value.translation.height
                        pendingRatio = min(0.85, max(0.15, ratio + delta / max(1, total)))
                    }
                    .onEnded { value in
                        let delta = direction == .horizontal
                            ? value.translation.width
                            : value.translation.height
                        let committed = min(0.85, max(0.15, ratio + delta / max(1, total)))
                        pendingRatio = nil
                        if let paneID = first.paneIDs.first {
                            model.setSplitRatio(
                                paneID: paneID,
                                splitID: splitID,
                                ratio: committed
                            )
                        }
                    }
            )
    }
}

private struct StackLayoutView: View {
    let model: FrontendModel
    let snapshot: ResourceSnapshot
    let paneIDs: [String]
    let expandedPaneID: String

    var body: some View {
        VStack(spacing: 2) {
            ForEach(paneIDs.filter { $0 != expandedPaneID }, id: \.self) { paneID in
                Button {
                    model.focusPane(paneID)
                } label: {
                    HStack {
                        Image(systemName: "rectangle.compress.vertical")
                        Text(snapshot.pane(paneID)?.name
                            ?? L10n.format("pane.short_id", "Pane %@", String(paneID.suffix(5))))
                            .lineLimit(1)
                        Spacer()
                    }
                    .font(.caption)
                    .padding(.horizontal, 8)
                    .frame(height: 25)
                    .background(.bar, in: .rect(cornerRadius: 4))
                }
                .buttonStyle(.plain)
            }
            PaneView(model: model, snapshot: snapshot, paneID: expandedPaneID)
        }
    }
}
