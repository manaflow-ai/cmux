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
        .onKeyPress(.escape) { fieldFocus = false; return .handled }
        .onKeyPress(.upArrow) {
            if !hits.isEmpty {
                selection = max(0, selection - 1)
                preview(hits[selection])
            }
            return .handled
        }
        .onKeyPress(.downArrow) {
            if !hits.isEmpty {
                selection = min(hits.count - 1, selection + 1)
                preview(hits[selection])
            }
            return .handled
        }
        .onKeyPress(keys: Set("123456789".map { KeyEquivalent($0) })) { press in
            guard press.modifiers.contains(.command),
                  let n = Int(press.characters), hits.indices.contains(n - 1) else {
                return .ignored
            }
            pick(hits[n - 1])
            return .handled
        }
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
        // Smart scope-prefix: "t:foo" / "b:foo" / "m:foo" / "w:foo"
        // narrows to terminal / browser / markdown / window-title.
        let trimmed = q.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, let index else {
            await MainActor.run { hits = [] }
            return
        }
        let (scope, body) = parseScope(trimmed)
        let raw = await index.search(body, limit: 80)
        let scoped = scope.map { k in raw.filter { $0.kind == k } } ?? raw
        let ranked = SmartRanker.shared.rank(scoped)
        SmartRanker.shared.recordImpressions(ranked)

        await MainActor.run {
            hits = Array(ranked.prefix(50))
            selection = 0
        }
    }

    private func parseScope(_ q: String) -> (SearchIndex.Kind?, String) {
        let map: [String: SearchIndex.Kind] = [
            "t:": .terminal, "b:": .browser,
            "m:": .markdown, "w:": .title,
        ]
        for (p, k) in map where q.lowercased().hasPrefix(p) {
            return (k, String(q.dropFirst(p.count)).trimmingCharacters(in: .whitespaces))
        }
        return (nil, q)
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

    @State private var previewTask: Task<Void, Never>?

    private func preview(_ hit: SearchIndex.Hit) {
        // Debounce: only fire if the user dwells on a row briefly
        // (no thrash when holding arrow keys).
        previewTask?.cancel()
        previewTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 120_000_000)
            guard !Task.isCancelled else { return }
            NotificationCenter.default.post(
                name: .cmuxPreviewSearchHit, object: hit)
        }
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
