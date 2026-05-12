import AppKit
import SwiftUI

/// Inline search field for the window titlebar accessory, sitting
/// immediately to the left of the "+" new-workspace button.
///
/// Wiring step (one line; see docs/menubar-global-search.md):
/// inside `TitlebarControls` body, just before the `TitlebarControlButton`
/// whose icon is `"plus"` (currently `Sources/Update/UpdateTitlebarAccessory.swift`
/// around line 582), insert:
///
///     TitlebarSearchField(config: config)
///         .frame(width: 220)
///
/// The field expands to a popover on focus and routes results through
/// the same `MenubarSearchPopover` machinery (without the menubar
/// status item). Ranking pipeline: Synapse hybrid → SQLite FTS5 →
/// `SmartRanker` (recency + click-history prior).
@MainActor
public struct TitlebarSearchField: View {
    public init(index: SearchIndex? = nil) {
        self.index = index
    }

    let index: SearchIndex?

    @State private var query: String = ""
    @State private var focused: Bool = false
    @State private var hits: [SearchIndex.Hit] = []
    @State private var selection: Int = 0
    @FocusState private var fieldFocus: Bool

    public var body: some View {
        ZStack(alignment: .leading) {
            background
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .font(.system(size: 11, weight: .semibold))
                TextField(
                    String(localized: "titlebar.search.placeholder",
                           defaultValue: "Search windows, panels, browser…"),
                    text: $query
                )
                .textFieldStyle(.plain)
                .focused($fieldFocus)
                .font(.system(size: 12))
                .onChange(of: query) { _, new in Task { await refresh(new) } }
                .onSubmit { acceptSelected() }
                if !query.isEmpty {
                    Button(action: { query = "" }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8)
        }
        .frame(height: 22)
        .popover(isPresented: Binding(
            get: { fieldFocus && !hits.isEmpty },
            set: { if !$0 { fieldFocus = false } }
        ), arrowEdge: .bottom) {
            ResultsList(hits: hits, selection: $selection, onPick: pick(_:))
                .frame(width: 480, height: 320)
        }
        .onAppear {
            // Pre-warm Synapse + ranker so first keystroke is instant.
            Task.detached(priority: .utility) {
                _ = await SynapseBridge.shared.hybrid("warmup", k: 1)
            }
        }
        .onKeyPress(.escape) { fieldFocus = false; return .handled }
        .onReceive(NotificationCenter.default.publisher(for: .cmuxFocusTitlebarSearch)) { _ in
            fieldFocus = true
        }
    }

    private var background: some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(Color(nsColor: .controlBackgroundColor).opacity(fieldFocus ? 1 : 0.6))
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(Color(nsColor: .separatorColor).opacity(fieldFocus ? 0.9 : 0.4),
                            lineWidth: 1)
            )
    }

    private func refresh(_ q: String) async {
        let trimmed = q.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { hits = []; return }

        // Parallel fan-out: Synapse (semantic) + FTS5 (lexical), merged.
        async let synapse = SynapseBridge.shared.hybrid(trimmed, k: 50)
        async let fts: [SearchIndex.Hit] = {
            guard let index else { return [] }
            return await index.search(trimmed)
        }()

        let (sem, lex) = await (synapse, fts)
        let merged = merge(synapse: sem, fts: lex)
        let ranked = SmartRanker.shared.rank(merged)
        SmartRanker.shared.recordImpressions(ranked)

        await MainActor.run {
            hits = ranked
            selection = 0
        }
    }

    private func merge(synapse: [SynapseBridge.Hit],
                       fts: [SearchIndex.Hit]) -> [SearchIndex.Hit] {
        // FTS hits carry full panel routing; Synapse hits carry semantic
        // score. Use synapse score as bonus on matching FTS rows (id ==
        // panelID); pass through FTS-only rows untouched.
        let semScore = Dictionary(uniqueKeysWithValues:
            synapse.map { ($0.id, $0.score) })
        return fts.map { hit in
            guard let s = semScore[hit.panelID.uuidString] else { return hit }
            return SearchIndex.Hit(
                panelID: hit.panelID, workspaceID: hit.workspaceID,
                windowID: hit.windowID, kind: hit.kind,
                snippet: hit.snippet,
                rank: max(0.001, hit.rank * (1.0 - 0.5 * s))  // boost
            )
        }
    }

    private func acceptSelected() {
        guard hits.indices.contains(selection) else { return }
        pick(hits[selection])
    }

    private func pick(_ hit: SearchIndex.Hit) {
        SmartRanker.shared.reward(hit)
        NotificationCenter.default.post(
            name: .cmuxJumpToSearchHit, object: hit)
        fieldFocus = false
        query = ""
    }
}

private struct ResultsList: View {
    let hits: [SearchIndex.Hit]
    @Binding var selection: Int
    let onPick: (SearchIndex.Hit) -> Void

    var body: some View {
        ScrollViewReader { proxy in
            List(Array(hits.enumerated()), id: \.offset, selection: $selection) { idx, hit in
                HStack(spacing: 8) {
                    Text(hit.kind.rawValue.uppercased())
                        .font(.system(size: 9, weight: .semibold))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(.secondary.opacity(0.15), in: Capsule())
                    Text(hit.snippet).lineLimit(1)
                    Spacer()
                    if idx < 9 {
                        Text("⌘\(idx + 1)")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
                .id(idx)
                .onTapGesture { onPick(hit) }
            }
            .listStyle(.plain)
        }
    }
}
