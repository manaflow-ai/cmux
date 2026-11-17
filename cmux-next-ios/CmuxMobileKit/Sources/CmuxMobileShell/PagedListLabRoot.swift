#if DEBUG && os(iOS)
import CmuxMobileDesign
import Observation
import SwiftUI

private let theme = CmuxMobileTheme.standard

/// The shared infinite-scroll list (``PagedList``) on fixed, generated data, for its UI tests
/// (`PagedListUITests`) and the screenshots of every state (verify/paged-list.md).
/// Launch with `-cmux-mobile-paged-lab DIRECTION:SCENARIO`:
/// - DIRECTION: `down` (newest at the top, older pages below) or `up` (a chat: newest at the
///   bottom, older pages above, a composer under it);
/// - SCENARIO: `normal` (30-row pages, 0.4 s each, 20 pages), `slow` (2.5 s a page: the edge's
///   spinner shows), `fast` (50 pages at 0.05 s, for fling hitches), `end` (two pages, then the
///   end), `empty`, `firstfail` (the first read fails once), `morefail` (the second page fails
///   once), `live` (a new row arrives every 1.5 s).
/// `-cmux-mobile-gallery-appearance light|dark` picks the scheme; `-cmux-mobile-paged-lab-clean`
/// hides the measurement line for screenshots.
public struct PagedListLabRoot: View {
    public static var isRequested: Bool {
        ProcessInfo.processInfo.arguments.contains("-cmux-mobile-paged-lab")
    }

    let direction: PagedListDirection
    let scenario: PagedLabScenario
    let scheme: ColorScheme?
    let clean: Bool
    @State private var model: PagedListModel<PagedLabItem>
    @State private var hud = PagedLabHUD()
    @State private var probe = PagedListProbe()
    @State private var draft = ""
    @State private var sent = 0

    public init(arguments: [String] = ProcessInfo.processInfo.arguments) {
        func value(_ flag: String) -> String? {
            arguments.firstIndex(of: flag).flatMap { i in arguments.indices.contains(i + 1) ? arguments[i + 1] : nil }
        }
        let parts = (value("-cmux-mobile-paged-lab") ?? "down:normal").split(separator: ":").map(String.init)
        let direction = PagedListDirection(rawValue: parts.first ?? "down") ?? .down
        let scenario = PagedLabScenario(rawValue: parts.count > 1 ? parts[1] : "normal") ?? .normal
        self.direction = direction
        self.scenario = scenario
        let look = value("-cmux-mobile-gallery-appearance")
        scheme = look == "dark" ? .dark : look == "light" ? .light : nil
        clean = arguments.contains("-cmux-mobile-paged-lab-clean")
        let source = PagedLabSource(scenario: scenario)
        _model = State(initialValue: PagedListModel(direction: direction) { cursor in try await source.page(after: cursor) })
    }

    public var body: some View {
        NavigationStack {
            PagedList(direction: direction, items: model.items, phase: model.phase, edge: model.edge,
                      loadMore: { Task { await model.loadMore() } }, retry: { await model.retry() }) { item in
                if direction == .up { PagedLabBubble(item: item) } else { PagedLabRow(item: item) }
            } empty: {
                ContentUnavailableView("Nothing Here Yet", systemImage: "tray",
                                       description: Text("New items show here."))
            }
            .pagedSwipeActions { item in
                [PagedListAction("Archive", systemImage: "archivebox", tint: .indigo, removesRow: true) { model.remove(item.id) }]
            }
            .pagedEndLabel(direction == .up ? "Beginning of the conversation" : "You're all caught up")
            .pagedIdentifier("lab.list")
            .pagedProbe(probe)
            .background(theme.colors.bg.color.ignoresSafeArea())
            .navigationTitle(direction == .up ? "Chat" : "Feed")
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(spacing: 0) {
                    if !clean { hudLine }
                    if direction == .up { composer }
                }
            }
        }
        .preferredColorScheme(scheme)
        .task {
            probe.pageLanded = { [hud] shift, rows in hud.landed(shift: shift, rows: rows) }
            probe.scrolling = { [hud] moving in hud.scrolling(moving) }
            await model.loadFirst()
        }
        .task {
            guard scenario == .live else { return }
            var next = -1
            while !Task.isCancelled {
                // motion: not an animation; the lab's live source sends a row every 1.5 s.
                try? await Task.sleep(for: .seconds(1.5))
                model.receiveNewest([PagedLabItem(id: next)])
                next -= 1
            }
        }
    }

    private var hudLine: some View {
        Text(hud.line)
            .font(theme.type.meta)
            .monospacedDigit()
            .foregroundStyle(theme.colors.label2.color)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
            .background(.bar)
            .accessibilityIdentifier("lab.hud")
            .accessibilityValue(hud.json(edge: edgeName))
    }

    private var edgeName: String {
        switch model.edge {
        case .more: "more"
        case .loading: "loading"
        case .failed: "failed"
        case .end: "end"
        }
    }

    private var composer: some View {
        HStack(spacing: 8) {
            TextField("Message", text: $draft)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("lab.composer")
            Button("Send") {
                sent += 1
                model.receiveNewest([PagedLabItem(id: -1000 - sent, mine: true, text: draft.isEmpty ? "Sent \(sent)" : draft)])
                draft = ""
            }
            .buttonStyle(.cmuxPressFill)
            .accessibilityIdentifier("lab.send")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }
}

enum PagedLabScenario: String, Sendable {
    case normal, slow, fast, end, empty, firstfail, morefail, live

    var pageSize: Int { 30 }
    var pages: Int {
        switch self {
        case .end: 2
        case .empty: 0
        case .fast: 50
        default: 20
        }
    }

    var latency: Duration {
        switch self {
        case .slow: .seconds(2.5)
        case .fast: .milliseconds(50)
        default: .milliseconds(400)
        }
    }
}

/// One generated row: its number (0 is the newest; live rows are negative), 1 to 5 lines of text.
struct PagedLabItem: Identifiable, Equatable, Sendable {
    let id: Int
    let mine: Bool
    let text: String

    init(id: Int, mine: Bool? = nil, text: String? = nil) {
        self.id = id
        self.mine = mine ?? (abs(id) % 3 == 0)
        let words = ["the", "list", "keeps", "what", "you", "read", "in", "place", "while", "older", "pages", "land",
                     "above", "and", "below", "with", "no", "jump", "flicker", "or", "hitch"]
        let count = 4 + (abs(id) * 7 % 5) * 9
        self.text = text ?? (0..<count).map { words[(abs(id) + $0 * 3) % words.count] }.joined(separator: " ")
    }
}

/// The lab's paged source: pages of generated rows after a fixed delay, failing where the scenario says.
@MainActor
final class PagedLabSource {
    let scenario: PagedLabScenario
    private var failedFirst = false
    private var failedMore = false

    init(scenario: PagedLabScenario) { self.scenario = scenario }

    struct Failure: LocalizedError {
        var errorDescription: String? { "The lab's source failed on purpose." }
    }

    func page(after cursor: String?) async throws -> PagedListPage<PagedLabItem> {
        // motion: not an animation; the lab's source answers after a network-like delay.
        try await Task.sleep(for: scenario.latency)
        let start = cursor.flatMap(Int.init) ?? 0
        if scenario == .firstfail, cursor == nil, !failedFirst {
            failedFirst = true
            throw Failure()
        }
        if scenario == .morefail, start == scenario.pageSize, !failedMore {
            failedMore = true
            throw Failure()
        }
        let total = scenario.pageSize * scenario.pages
        let end = min(total, start + scenario.pageSize)
        let items = (start..<max(start, end)).map { PagedLabItem(id: $0) }
        return PagedListPage(items: items, nextCursor: end < total ? String(end) : nil)
    }
}

/// What the lab measured: rows, page landings and the worst shift of the row being read, and the
/// frames of every scroll (FrameIntervalLog windows from drag start to rest).
@MainActor
@Observable
final class PagedLabHUD {
    var rows = 0
    var landings = 0
    var maxShift: CGFloat = 0
    var frames = 0
    var hitches = 0
    var dropped = 0
    var worstMs: Double = 0
    var hitchMs: Double = 0
    var seconds: Double = 0
    @ObservationIgnored private let log = FrameIntervalLog(enabled: true)

    init() {
        // Every window, also one a new drag ends early (`begin` ends the open one).
        log.onSummary = { [weak self] stats in self?.add(stats) }
    }

    private func add(_ stats: FrameIntervalStats) {
        frames += stats.frames
        hitches += stats.hitches
        dropped += stats.droppedFrames
        worstMs = max(worstMs, stats.maxMs)
        hitchMs += stats.hitchMsPerSecond * stats.durationSeconds
        seconds += stats.durationSeconds
    }

    func landed(shift: CGFloat, rows: Int) {
        self.rows = rows
        landings += 1
        maxShift = max(maxShift, shift)
    }

    func scrolling(_ moving: Bool) {
        if moving { log.begin("paged-lab") } else { log.end() }
    }

    var line: String {
        let shift = String(format: "%.1f", maxShift)
        return "rows \(rows) · pages \(landings) · max shift \(shift) pt · hitches \(hitches)/\(frames) · worst \(Int(worstMs)) ms"
    }

    func json(edge: String) -> String {
        let ratio = seconds > 0 ? hitchMs / seconds : 0
        return #"{"edge":"\#(edge)","rows":\#(rows),"landings":\#(landings),"maxShift":\#(maxShift),"frames":\#(frames),"hitches":\#(hitches),"dropped":\#(dropped),"worstMs":\#(worstMs),"hitchMsPerS":\#(ratio)}"#
    }
}

struct PagedLabRow: View {
    let item: PagedLabItem

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Item \(item.id)")
                .font(theme.type.rowTitle)
                .foregroundStyle(theme.colors.label.color)
            Text(item.text)
                .font(theme.type.rowSubtitle)
                .foregroundStyle(theme.colors.label2.color)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color(uiColor: .separator)).frame(height: 1 / 3).padding(.leading, 16)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("lab.row.\(item.id)")
    }
}

struct PagedLabBubble: View {
    let item: PagedLabItem

    var body: some View {
        HStack {
            if item.mine { Spacer(minLength: 48) }
            VStack(alignment: .leading, spacing: 2) {
                Text("#\(item.id)").font(theme.type.meta).opacity(0.7)
                Text(item.text).font(theme.type.body)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .foregroundStyle(item.mine ? Color.white : theme.colors.label.color)
            .background(item.mine ? Color.accentColor : Color(uiColor: .secondarySystemBackground),
                        in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            if !item.mine { Spacer(minLength: 48) }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("lab.row.\(item.id)")
    }
}
#endif
