#if os(iOS)
import CmuxMobileDesign
import SwiftUI
import UIKit

/// SPEC 12.2: one file's diff with a sticky header, unified or split rows,
/// collapsed context that expands, word highlights, and prev/next/viewed in the bottom toolbar.
public struct DiffFileScreen: View {
    @State private var state: DiffViewerState
    @State private var fileID: String
    @State private var expanded: [String: [ClosedRange<Int>]] = [:]
    @ScaledMetric(relativeTo: .footnote) private var codeSize: CGFloat = 13
    @Environment(\.openSessionFile) private var openFile
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var viewportWidth: CGFloat = 400
    /// The rows, texts and heights, prepared off the main thread once per (file, options, style).
    @State private var renderer = DiffRenderer()

    init(state: DiffViewerState, fileID: String) {
        _state = State(initialValue: state)
        _fileID = State(initialValue: fileID)
    }

    /// Opens a file directly (a transcript diff header tap).
    public init(changeSet: DiffChangeSet, fileID: String) {
        self.init(state: DiffViewerState(changeSet: changeSet), fileID: fileID)
    }

    private var files: [DiffFile] { state.changeSet.files }
    private var index: Int { files.firstIndex { $0.id == fileID } ?? 0 }
    private var file: DiffFile { files[index] }

    /// Split needs two readable columns; on a phone the layout stays Unified.
    private var layout: DiffViewerState.Layout {
        DiffLayout.allowsSplit(width: viewportWidth) ? state.layout : .unified
    }

    /// What the list shows and how: a change prepares a new render model.
    private var renderKey: DiffRenderKey {
        let layout = layout
        let wrap = state.wrapLines
        let split = layout == .split
        return DiffRenderKey(
            fileID: file.id, contentHash: file.contentHash,
            options: DiffRows.Options(hideWhitespace: state.hideWhitespace, split: split, expanded: expanded[file.id] ?? []),
            // Unwrapped unified rows do not depend on the width (the layout fills it).
            style: DiffRenderStyle(codeSize: codeSize, wrap: wrap, split: split, width: wrap || split ? viewportWidth.rounded() : 0)
        )
    }

    public var body: some View {
        let isViewed = state.isViewed(file)
        let file = file
        let renderKey = renderKey
        Group {
            if isViewed {
                ScrollView {
                    Label("Viewed. Tap Viewed to show the diff again.", systemImage: "checkmark.circle.fill")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(20)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .transition(.opacity)
                }
                .scrollEdgeEffectStyle(.hard, for: .top)
            } else if let model = renderer.model, model.key.fileID == file.id {
                DiffCodeList(model: model) { expand($0) }
                    .ignoresSafeArea(.container, edges: .bottom)
                    .transition(.opacity)
            } else {
                Color(uiColor: .systemBackground)
            }
        }
        .task(id: renderKey) { await renderer.update(file: file, key: renderKey) }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { viewportWidth = $0 }
        .safeAreaInset(edge: .top, spacing: 0) { stickyHeader(isViewed: isViewed) }
        .navigationTitle(file.fileName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { DiffOptionsMenu(state: state, allowsSplit: DiffLayout.allowsSplit(width: viewportWidth)) }
            ToolbarItemGroup(placement: .bottomBar) {
                Button("Previous file", systemImage: "chevron.up") { move(-1) }
                    .disabled(index == 0)
                Button("Next file", systemImage: "chevron.down") { move(1) }
                    .disabled(index >= files.count - 1)
            }
            ToolbarSpacer(.flexible, placement: .bottomBar)
            ToolbarItem(placement: .bottomBar) {
                Button {
                    withAnimation(.cmuxMobileSmooth) { state.toggleViewed(file) }
                } label: {
                    // The same name as the header's check ("Viewed"), so the copy above matches it.
                    Label(isViewed ? "Viewed" : "Mark Viewed", systemImage: isViewed ? "checkmark.circle.fill" : "checkmark.circle")
                        .labelStyle(.titleAndIcon)
                        .fixedSize()
                }
            }
        }
        .toolbar(.hidden, for: .tabBar)
        #if DEBUG
        .onChange(of: DemoDirector.shared.serial) { runDemoCommand() }
        #endif
    }

    #if DEBUG
    private func runDemoCommand() {
        switch DemoDirector.shared.command {
        case .diffSetSplit(let split)?:
            withAnimation(.cmuxMobileSmooth) { state.layout = split ? .split : .unified }
        case .diffExpandFirst?:
            if let range = renderer.model?.rows.firstCollapsed { expand(range) }
        case .diffMarkViewed?:
            withAnimation(.cmuxMobileSmooth) { state.toggleViewed(file) }
        case .navigateBack?:
            dismiss()
        default:
            break
        }
    }
    #endif

    private func move(_ delta: Int) {
        let next = index + delta
        guard files.indices.contains(next) else { return }
        withAnimation(.cmuxMobileSnap) { fileID = files[next].id }
    }

    /// The file header: badge, path (the folder truncates, never the file name), counts,
    /// Mark viewed and File actions (44 pt each). At accessibility sizes the counts and
    /// buttons move to a second line so the file name keeps the width.
    private func stickyHeader(isViewed: Bool) -> some View {
        // The folder takes only the width the whole name leaves, and is left out under
        // about three characters (no sliver or lone glyph).
        let path = FolderNameLayout(folderFirst: true) {
            // `directory` already ends in "/".
            Text(file.directory)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.head)
                .frame(minWidth: 0, alignment: .leading)
                .clipped()
            Text(file.fileName)
                // At accessibility sizes a long name wraps to a second line instead of losing its middle.
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
                .truncationMode(.middle)
        }
        .font(.footnote.monospaced())
        .accessibilityElement(children: .combine)
        let controls = HStack(spacing: 0) {
            DiffCounts(additions: file.additions, deletions: file.deletions)
                .padding(.trailing, 4)
            ViewedToggle(isViewed: isViewed) { withAnimation(.cmuxMobileSmooth) { state.toggleViewed(file) } }
            Menu {
                if openFile.isAvailable, file.status != .deleted {
                    Button("Open File", systemImage: "doc.text.magnifyingglass") { openFile(file.path) }
                }
                Button("Copy Path", systemImage: "doc.on.doc") { UIPasteboard.general.string = file.path }
            } label: {
                Image(systemName: "ellipsis").frame(width: 44, height: 44).contentShape(.rect)
            }
            .accessibilityLabel("File actions")
        }
        return Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 10) {
                        StatusBadge(status: file.status)
                        path
                    }
                    .padding(.top, 6)
                    HStack(spacing: 0) {
                        Spacer(minLength: 0)
                        controls
                    }
                }
            } else {
                HStack(spacing: 10) {
                    StatusBadge(status: file.status)
                    path
                    Spacer(minLength: 4)
                    controls
                }
            }
        }
        .padding(.leading, 16)
        .padding(.trailing, 6)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }

    private func expand(_ range: ClosedRange<Int>) {
        let chunk: ClosedRange<Int> = range.count > 40 ? range.lowerBound...range.lowerBound + 19 : range
        withAnimation(.cmuxMobileSmooth) {
            expanded[file.id, default: []].append(chunk)
        }
    }
}

extension DiffLine {
    /// VoiceOver's reading of the row. A snippet edit has no line numbers (where it sits in
    /// the file is unknown): it reads without one, never "line 0" (full verify D6).
    var accessibilityText: String {
        func at(_ number: Int?) -> String { number.map { " \($0)" } ?? "" }
        return switch kind {
        case .added: "added line\(at(newNumber)): \(text)"
        case .removed: "removed line\(at(oldNumber)): \(text)"
        case .context: "line\(at(newNumber)): \(text)"
        }
    }
}

#endif
