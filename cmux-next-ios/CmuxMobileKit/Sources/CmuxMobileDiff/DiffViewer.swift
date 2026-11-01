#if os(iOS)
import CmuxMobileDesign
import SwiftUI
import UIKit

/// SPEC 12.1: the Changes file list (GitHub mobile style).
public struct DiffChangesScreen: View {
    @State private var state: DiffViewerState
    @State private var listWidth: CGFloat = 400

    public init(changeSet: DiffChangeSet) {
        _state = State(initialValue: DiffViewerState(changeSet: changeSet))
    }

    public var body: some View {
        // The viewed marks once per body (a set lookup per file), for the rows, the filter and the summary.
        let viewed = state.viewed
        let files = state.showViewed ? state.changeSet.files : state.changeSet.files.filter { !viewed.contains($0.id) }
        List {
            Section {
                summary(viewedCount: viewed.count)
                    .listRowSeparator(.hidden, edges: .top)
                ForEach(files) { file in
                    // A destination link, not a value link: the chat that pushes this
                    // screen may sit in a stack with a typed path (Home), where a
                    // DiffFileRoute value has nowhere to go and the tap did nothing.
                    NavigationLink {
                        DiffFileScreen(state: state, fileID: file.id)
                    } label: {
                        DiffFileRow(file: file, isViewed: viewed.contains(file.id)) {
                            withAnimation(.cmuxMobileSnap) { state.toggleViewed(file) }
                        }
                        .equatable()
                    }
                }
            }
        }
        .listStyle(.plain)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { listWidth = $0 }
        .navigationTitle(state.changeSet.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                VStack(spacing: 1) {
                    Text(state.changeSet.title).font(.headline)
                    Text("\(state.changeSet.subtitle) · \(state.changeSet.files.count) \(state.changeSet.files.count == 1 ? "file" : "files")").font(.footnote).foregroundStyle(.secondary)
                }
            }
            ToolbarItem(placement: .topBarTrailing) { DiffOptionsMenu(state: state, allowsSplit: DiffLayout.allowsSplit(width: listWidth)) }
        }
    }

    private func summary(viewedCount: Int) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("\(state.changeSet.files.count) \(state.changeSet.files.count == 1 ? "file" : "files") changed").font(.headline)
            HStack(spacing: 8) {
                DiffCounts(additions: state.changeSet.additions, deletions: state.changeSet.deletions)
                DiffStatBar(additions: state.changeSet.additions, deletions: state.changeSet.deletions)
                Spacer()
                Text("\(viewedCount) of \(state.changeSet.files.count) viewed").font(.footnote).foregroundStyle(.secondary)
                    .contentTransition(.numericText())
            }
        }
        .padding(.vertical, 6)
    }
}

/// `+12 −4` in diff colors.
public struct DiffCounts: View {
    let additions: Int
    let deletions: Int

    public init(additions: Int, deletions: Int) {
        self.additions = additions
        self.deletions = deletions
    }

    public var body: some View {
        HStack(spacing: 4) {
            Text("+\(additions)").foregroundStyle(Color.cmuxMobileDiffAddText)
            Text("−\(deletions)").foregroundStyle(Color.cmuxMobileDiffDelText)
        }
        .font(.footnote.monospacedDigit().weight(.medium))
        .lineLimit(1)
        .fixedSize()
        .accessibilityElement()
        .accessibilityLabel(Text("\(additions) additions, \(deletions) deletions"))
    }
}

/// GitHub's five squares.
struct DiffStatBar: View {
    let additions: Int
    let deletions: Int

    var body: some View {
        let total = max(additions + deletions, 1)
        let green = Int((Double(additions) / Double(total) * 5).rounded())
        let red = min(5 - green, Int((Double(deletions) / Double(total) * 5).rounded()))
        HStack(spacing: 2) {
            ForEach(0..<5, id: \.self) { index in
                RoundedRectangle(cornerRadius: 2)
                    .fill(index < green ? Color.cmuxMobileDiffAddText : (index < green + red ? Color.cmuxMobileDiffDelText : Color.cmuxMobileFillSelected))
                    .frame(width: 8, height: 8)
            }
        }
        .accessibilityHidden(true)
    }
}

struct StatusBadge: View {
    let status: DiffFile.Status

    var body: some View {
        Text(status.rawValue)
            .font(.caption.weight(.semibold).monospaced())
            .foregroundStyle(color)
            .lineLimit(1)
            .fixedSize()
            // Grows with its glyph at accessibility sizes instead of clipping it.
            .padding(.horizontal, 3)
            .padding(.vertical, 1)
            .frame(minWidth: 20, minHeight: 20)
            .background(color.opacity(0.18), in: .rect(cornerRadius: 5))
            .accessibilityLabel(Text(label))
    }

    private var color: Color {
        switch status {
        case .modified: .cmuxMobileWarning
        case .added: .cmuxMobileSuccess
        case .deleted: .cmuxMobileDanger
        case .renamed: .secondary
        }
    }

    private var label: String {
        switch status {
        case .modified: "Modified"
        case .added: "Added"
        case .deleted: "Deleted"
        case .renamed: "Renamed"
        }
    }
}

/// Equatable on its content (the file's path and fingerprint, and the mark), so a body
/// of the list skips rows that did not change; the toggle closure is new every body.
struct DiffFileRow: View, Equatable {
    let file: DiffFile
    let isViewed: Bool
    let toggleViewed: () -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.isViewed == rhs.isViewed && lhs.file.path == rhs.file.path && lhs.file.contentHash == rhs.file.contentHash
            && lhs.file.status == rhs.file.status
    }

    var body: some View {
        if dynamicTypeSize.isAccessibilitySize {
            // Accessibility sizes: the name gets the full width (two lines), the counts and
            // Mark viewed go under it.
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    StatusBadge(status: file.status)
                    Text(file.fileName).font(.body).lineLimit(2).truncationMode(.middle)
                }
                if !file.directory.isEmpty {
                    Text(file.directory).font(.footnote).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                }
                HStack(spacing: 0) {
                    DiffCounts(additions: file.additions, deletions: file.deletions)
                    Spacer(minLength: 8)
                    ViewedToggle(isViewed: isViewed, action: toggleViewed)
                }
            }
            .opacity(isViewed ? 0.6 : 1)
        } else {
            row
        }
    }

    private var row: some View {
        HStack(spacing: 12) {
            StatusBadge(status: file.status)
            VStack(alignment: .leading, spacing: 2) {
                Text(file.fileName).font(.body).lineLimit(1)
                if !file.directory.isEmpty {
                    Text(file.directory).font(.footnote).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                }
            }
            Spacer(minLength: 8)
            DiffCounts(additions: file.additions, deletions: file.deletions)
            ViewedToggle(isViewed: isViewed, action: toggleViewed)
        }
        .frame(minHeight: 44)
        .opacity(isViewed ? 0.6 : 1)
    }
}

struct ViewedToggle: View {
    let isViewed: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: isViewed ? "checkmark.circle.fill" : "checkmark.circle")
                .font(.system(size: 20))
                .foregroundStyle(isViewed ? Color.cmuxMobileSuccess : Color.secondary)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 44, height: 44)
                .contentShape(.rect)
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(isViewed ? "Viewed" : "Mark as viewed")
        .sensoryFeedback(.selection, trigger: isViewed)
    }
}

struct DiffOptionsMenu: View {
    @Bindable var state: DiffViewerState
    /// Split is offered only where two columns fit (700 pt or more).
    var allowsSplit: Bool

    init(state: DiffViewerState, allowsSplit: Bool = false) {
        self.state = state
        self.allowsSplit = allowsSplit
    }

    var body: some View {
        Menu {
            if allowsSplit {
                Picker("Layout", selection: $state.layout) {
                    ForEach(DiffViewerState.Layout.allCases, id: \.self) { Text($0.rawValue) }
                }
                .pickerStyle(.inline)
            }
            Toggle("Wrap Lines", systemImage: "text.word.spacing", isOn: $state.wrapLines)
            Toggle("Hide Whitespace", systemImage: "space", isOn: $state.hideWhitespace)
            Toggle("Show Viewed Files", systemImage: "checkmark.circle", isOn: $state.showViewed)
        } label: {
            // A Label: the bar hosts a native button that takes the whole 44 pt circle.
            Label("Diff options", systemImage: "ellipsis")
        }
        .accessibilityLabel("Diff options")
    }
}
#endif
