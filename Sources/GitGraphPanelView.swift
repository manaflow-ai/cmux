import AppKit
import CmuxGit
import Observation
import SwiftUI

enum GitGraphAccessibility {
    static func commitLabel(
        subject: String,
        author: String,
        abbreviatedOID: String,
        locale: Locale = .current
    ) -> String {
        String(
            localized: "gitGraph.commit.accessibilityLabel",
            defaultValue: "\(subject), \(author), \(abbreviatedOID)",
            locale: locale
        )
    }
}

@MainActor
@Observable
final class GitGraphPanelModel {
    enum State: Equatable {
        case idle
        case loading
        case loaded(GitGraphSnapshot)
        case notRepository
        case remoteUnsupported
        case failed
    }

    private(set) var state: State = .idle
    private(set) var directory: String?
    private var loadTask: Task<Void, Never>?

    func setDirectory(_ directory: String?, isRemote: Bool) {
        let normalized = directory?.trimmingCharacters(in: .whitespacesAndNewlines)
        let nextDirectory = normalized?.isEmpty == false ? normalized : nil
        let needsStateTransition = isRemote
            ? state != .remoteUnsupported
            : state == .remoteUnsupported
        guard self.directory != nextDirectory || needsStateTransition else { return }
        self.directory = nextDirectory
        loadTask?.cancel()
        if isRemote {
            state = .remoteUnsupported
        } else {
            state = .idle
            reload()
        }
    }

    func loadIfNeeded() {
        guard state == .idle else { return }
        reload()
    }

    func reload() {
        guard state != .remoteUnsupported else { return }
        guard let directory else {
            state = .notRepository
            return
        }
        loadTask?.cancel()
        state = .loading
        loadTask = Task { [weak self] in
            do {
                let snapshot = try await GitGraphService().snapshot(forDirectory: directory)
                guard !Task.isCancelled, self?.directory == directory else { return }
                self?.state = .loaded(snapshot)
            } catch GitGraphServiceError.notRepository {
                guard !Task.isCancelled, self?.directory == directory else { return }
                self?.state = .notRepository
            } catch {
                guard !Task.isCancelled, self?.directory == directory else { return }
                self?.state = .failed
            }
        }
    }

}

struct GitGraphPanelView: View {
    let model: GitGraphPanelModel
    let onFocus: () -> Void

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            toolbar(model: model)
            Divider()
            content(model: model)
        }
        .onAppear { model.loadIfNeeded() }
        .simultaneousGesture(TapGesture().onEnded { onFocus() })
        .accessibilityIdentifier("GitGraphPanel")
    }

    private func toolbar(model: GitGraphPanelModel) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.triangle.branch")
                .foregroundStyle(.secondary)
            if case .loaded(let snapshot) = model.state {
                Text(URL(fileURLWithPath: snapshot.repositoryRoot).lastPathComponent)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                GitGraphBranchBadge(snapshot: snapshot)
            } else {
                Text(String(localized: "gitGraph.title", defaultValue: "Git Graph"))
                    .font(.system(size: 12, weight: .semibold))
            }
            Spacer(minLength: 8)
            if case .loaded(let snapshot) = model.state,
               let truncationLabel = truncationLabel(for: snapshot.truncation) {
                Text(truncationLabel)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            Button { model.reload() } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.plain)
            .help(String(localized: "gitGraph.refresh", defaultValue: "Refresh Git Graph"))
            .accessibilityLabel(String(localized: "gitGraph.refresh", defaultValue: "Refresh Git Graph"))
        }
        .padding(.horizontal, 12)
        .frame(height: 38)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.35))
    }

    private func truncationLabel(for truncation: GitGraphTruncation) -> String? {
        switch truncation {
        case .none:
            nil
        case .commitLimit:
            String(localized: "gitGraph.limit", defaultValue: "Latest 500")
        case .outputLimit:
            String(localized: "gitGraph.outputLimit", defaultValue: "Partial history")
        }
    }

    @ViewBuilder
    private func content(model: GitGraphPanelModel) -> some View {
        switch model.state {
        case .idle, .loading:
            VStack(spacing: 10) {
                ProgressView()
                Text(String(localized: "gitGraph.loading", defaultValue: "Loading commit history…"))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .loaded(let snapshot):
            GitGraphHistoryView(snapshot: snapshot)
        case .notRepository:
            emptyState(
                icon: "arrow.triangle.branch",
                title: String(localized: "gitGraph.notRepository.title", defaultValue: "No Git repository"),
                detail: String(localized: "gitGraph.notRepository.detail", defaultValue: "Open this tab from a terminal inside a Git repository.")
            )
        case .remoteUnsupported:
            emptyState(
                icon: "network.slash",
                title: String(localized: "gitGraph.remoteUnsupported.title", defaultValue: "Remote Git Graph is not available yet"),
                detail: String(localized: "gitGraph.remoteUnsupported.detail", defaultValue: "Use Git Graph from a local terminal for now.")
            )
        case .failed:
            emptyState(
                icon: "exclamationmark.triangle",
                title: String(localized: "gitGraph.failed.title", defaultValue: "Could not load Git Graph"),
                detail: String(localized: "gitGraph.failed.detail", defaultValue: "Check the repository and refresh this tab.")
            )
        }
    }

    private func emptyState(icon: String, title: String, detail: String) -> some View {
        ContentUnavailableView {
            Label(title, systemImage: icon)
        } description: {
            Text(detail)
        }
    }
}

private struct GitGraphBranchBadge: View {
    let snapshot: GitGraphSnapshot

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "arrow.triangle.branch")
            Text(snapshot.branch ?? String(localized: "gitGraph.detachedHead", defaultValue: "Detached HEAD"))
            if snapshot.isDirty {
                Text("*")
                    .foregroundStyle(.orange)
            }
        }
        .font(.system(size: 10, weight: .medium))
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(.blue.opacity(0.14), in: Capsule())
        .foregroundStyle(.blue)
        .lineLimit(1)
        .help(snapshot.repositoryRoot)
    }
}

private struct GitGraphHistoryView: View {
    let snapshot: GitGraphSnapshot

    private var graphWidth: CGFloat {
        let laneCount = snapshot.rows.reduce(1) { partial, row in
            max(partial, max(row.incomingLanes.count, row.outgoingLanes.count))
        }
        return min(220, max(64, CGFloat(laneCount) * 18 + 22))
    }

    var body: some View {
        ScrollView([.horizontal, .vertical]) {
            LazyVStack(spacing: 0) {
                GitGraphColumnHeader(graphWidth: graphWidth)
                if snapshot.isDirty {
                    GitGraphDirtyRow(graphWidth: graphWidth)
                }
                ForEach(snapshot.rows) { row in
                    GitGraphCommitRow(
                        row: row,
                        graphWidth: graphWidth,
                        isHead: row.commit.oid == snapshot.headOID
                    )
                }
            }
            .frame(minWidth: 920, alignment: .topLeading)
        }
        .background(Color(nsColor: .textBackgroundColor))
    }
}

private struct GitGraphColumnHeader: View {
    let graphWidth: CGFloat

    var body: some View {
        HStack(spacing: 0) {
            Text(String(localized: "gitGraph.column.graph", defaultValue: "Graph"))
                .frame(width: graphWidth, alignment: .leading)
            Text(String(localized: "gitGraph.column.description", defaultValue: "Description"))
                .frame(width: 430, alignment: .leading)
            Text(String(localized: "gitGraph.column.date", defaultValue: "Date"))
                .frame(width: 135, alignment: .leading)
            Text(String(localized: "gitGraph.column.author", defaultValue: "Author"))
                .frame(width: 150, alignment: .leading)
            Text(String(localized: "gitGraph.column.commit", defaultValue: "Commit"))
                .frame(width: 80, alignment: .leading)
        }
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(Color(nsColor: .controlBackgroundColor))
        .overlay(alignment: .bottom) { Divider() }
    }
}

private struct GitGraphDirtyRow: View {
    let graphWidth: CGFloat

    var body: some View {
        HStack(spacing: 0) {
            ZStack {
                Rectangle().fill(.secondary.opacity(0.55)).frame(width: 2)
                Circle().fill(.orange).frame(width: 9, height: 9)
            }
            .frame(width: graphWidth, height: 34)
            Label(
                String(localized: "gitGraph.uncommittedChanges", defaultValue: "Uncommitted Changes"),
                systemImage: "pencil.line"
            )
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.orange)
            .frame(width: 430, alignment: .leading)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .frame(height: 34)
        .background(.orange.opacity(0.05))
        .overlay(alignment: .bottom) { Divider().opacity(0.45) }
    }
}

private struct GitGraphCommitRow: View {
    let row: GitGraphRow
    let graphWidth: CGFloat
    let isHead: Bool

    var body: some View {
        let abbreviatedOID = String(row.commit.oid.prefix(8))
        HStack(spacing: 0) {
            GitGraphLaneCanvas(row: row, isHead: isHead)
                .frame(width: graphWidth, height: 36)
            HStack(spacing: 6) {
                ForEach(row.commit.references.prefix(3)) { reference in
                    GitGraphReferenceBadge(reference: reference)
                }
                Text(row.commit.subject)
                    .font(.system(size: 12, weight: isHead ? .semibold : .regular))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(width: 430, alignment: .leading)
            Text(row.commit.authoredAt.formatted(date: .abbreviated, time: .shortened))
                .frame(width: 135, alignment: .leading)
            Text(row.commit.author)
                .frame(width: 150, alignment: .leading)
                .lineLimit(1)
            Text(abbreviatedOID)
                .font(.system(size: 11, design: .monospaced))
                .frame(width: 80, alignment: .leading)
        }
        .font(.system(size: 11))
        .foregroundStyle(isHead ? .primary : .secondary)
        .padding(.horizontal, 10)
        .frame(height: 36)
        .background(isHead ? Color.accentColor.opacity(0.09) : .clear)
        .overlay(alignment: .bottom) { Divider().opacity(0.28) }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            GitGraphAccessibility.commitLabel(
                subject: row.commit.subject,
                author: row.commit.author,
                abbreviatedOID: abbreviatedOID
            )
        )
    }
}

private struct GitGraphReferenceBadge: View {
    let reference: GitGraphReference

    private var color: Color {
        switch reference.kind {
        case .head, .branch: return .blue
        case .remote: return .pink
        case .tag: return .orange
        case .other: return .secondary
        }
    }

    var body: some View {
        Text(reference.name)
            .font(.system(size: 9, weight: .semibold))
            .lineLimit(1)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .foregroundStyle(color)
            .background(color.opacity(0.14), in: RoundedRectangle(cornerRadius: 4))
    }
}

private struct GitGraphLaneCanvas: View {
    let row: GitGraphRow
    let isHead: Bool

    private static let colors: [Color] = [
        .cyan, .pink, .green, .orange, .purple, .blue, .mint, .red,
    ]

    var body: some View {
        Canvas { context, size in
            let centerY = size.height / 2
            for (incomingIndex, lane) in row.incomingLanes.enumerated() {
                if lane.oid == row.commit.oid {
                    drawLine(
                        from: point(lane: incomingIndex, y: 0),
                        to: point(lane: row.nodeLane, y: centerY),
                        colorIndex: lane.colorIndex,
                        in: &context
                    )
                } else if let outgoingIndex = row.outgoingLanes.firstIndex(where: { $0.oid == lane.oid }) {
                    drawLine(
                        from: point(lane: incomingIndex, y: 0),
                        to: point(lane: outgoingIndex, y: size.height),
                        colorIndex: lane.colorIndex,
                        in: &context
                    )
                }
            }
            for parentOID in row.commit.parentOIDs {
                guard let outgoingIndex = row.outgoingLanes.firstIndex(where: { $0.oid == parentOID }) else { continue }
                let colorIndex = row.outgoingLanes[outgoingIndex].colorIndex
                drawLine(
                    from: point(lane: row.nodeLane, y: centerY),
                    to: point(lane: outgoingIndex, y: size.height),
                    colorIndex: colorIndex,
                    in: &context
                )
            }

            let nodeCenter = point(lane: row.nodeLane, y: centerY)
            let nodeRect = CGRect(x: nodeCenter.x - 4.5, y: nodeCenter.y - 4.5, width: 9, height: 9)
            context.fill(Path(ellipseIn: nodeRect), with: .color(color(row.nodeColorIndex)))
            if isHead {
                let ring = nodeRect.insetBy(dx: -3, dy: -3)
                context.stroke(Path(ellipseIn: ring), with: .color(.primary), lineWidth: 1.5)
            }
        }
    }

    private func point(lane: Int, y: CGFloat) -> CGPoint {
        CGPoint(x: 10 + CGFloat(lane) * 18, y: y)
    }

    private func drawLine(
        from start: CGPoint,
        to end: CGPoint,
        colorIndex: Int,
        in context: inout GraphicsContext
    ) {
        var path = Path()
        path.move(to: start)
        let midpoint = (start.y + end.y) / 2
        path.addCurve(
            to: end,
            control1: CGPoint(x: start.x, y: midpoint),
            control2: CGPoint(x: end.x, y: midpoint)
        )
        context.stroke(path, with: .color(color(colorIndex)), lineWidth: 2)
    }

    private func color(_ index: Int) -> Color {
        Self.colors[index % Self.colors.count]
    }
}
