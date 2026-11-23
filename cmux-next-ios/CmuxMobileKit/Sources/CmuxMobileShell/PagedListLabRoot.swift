#if DEBUG && os(iOS)
import CmuxMobileDesign
import CmuxMobileWorkspaces
import Observation
import SwiftUI

private let theme = CmuxMobileTheme.standard

/// The shared infinite-scroll list (``PagedList``) on fixed, generated data, for its UI tests
/// (`PagedListUITests`) and the screenshots of every state (verify/paged-list.md).
/// Launch with `-cmux-mobile-paged-lab DIRECTION:SCENARIO`:
/// - DIRECTION: `down` (newest at the top, older pages below) or `up` (a chat: newest at the
///   bottom, older pages above, a composer under it);
/// - SCENARIO: `normal` (30-row pages, 0.4 s each, 20 pages), `slow` (6 s a page: the edge's
///   spinner shows), `fast` (50 pages at 0.05 s, for fling hitches), `end` (two pages, then the
///   end), `empty`, `firstfail` (the first read fails once), `morefail` (the second page fails
///   once), `live` (a new row arrives every 1.5 s), `stall` (the first page at once, then a read
///   that doesn't answer for 10 minutes: the edge's spinner stays, for a screenshot).
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
    /// `agentchats:SCENARIO`: the Chats list itself (``AgentChatsGallery``) instead of the lab's rows.
    let agentChats: String?
    @State private var model: PagedListModel<PagedLabItem>
    /// The lab's source (held here: the model keeps it weakly). Its edits go out as changes, as a
    /// live backend's would, so a first page read again agrees with them.
    @State private var source: PagedLabSource
    /// `-cmux-mobile-paged-lab-stress LOAD`: the stress bench's source instead.
    @State private var stress: PagedStressSource?
    @State private var hud = PagedLabHUD()
    @State private var probe: PagedListProbe
    @State private var draft = ""
    /// The top banner (`lab.op.banner`): a top inset that comes and goes mid-list, like "Updating…".
    @State private var banner = false

    public init(arguments: [String] = ProcessInfo.processInfo.arguments) {
        func value(_ flag: String) -> String? {
            arguments.firstIndex(of: flag).flatMap { i in arguments.indices.contains(i + 1) ? arguments[i + 1] : nil }
        }
        let parts = (value("-cmux-mobile-paged-lab") ?? "down:normal").split(separator: ":").map(String.init)
        agentChats = parts.first == "agentchats" ? (parts.count > 1 ? parts[1] : "pages") : nil
        let direction = PagedListDirection(rawValue: parts.first ?? "down") ?? .down
        let scenario = PagedLabScenario(rawValue: parts.count > 1 ? parts[1] : "normal") ?? .normal
        self.direction = direction
        self.scenario = scenario
        let look = value("-cmux-mobile-gallery-appearance")
        scheme = look == "dark" ? .dark : look == "light" ? .light : nil
        clean = arguments.contains("-cmux-mobile-paged-lab-clean")
        // `-cmux-mobile-paged-lab-window N`: keep about N rows in memory, the rest on disk.
        let memory = value("-cmux-mobile-paged-lab-window").flatMap(Int.init).map(PagedListMemory.window) ?? .unbounded
        let source = PagedLabSource(scenario: scenario)
        _source = State(initialValue: source)
        let probe = PagedListProbe()
        _probe = State(initialValue: probe)
        if let name = value("-cmux-mobile-paged-lab-stress"), let load = PagedStressLoad.named[name] {
            let stress = PagedStressSource(load: load)
            _stress = State(initialValue: stress)
            _model = State(initialValue: PagedListModel(direction: direction, source: stress, memory: memory))
        } else {
            _model = State(initialValue: PagedListModel(direction: direction, source: source, memory: memory))
        }
    }

    public var body: some View {
        if let agentChats {
            AgentChatsGallery(scenario: agentChats).preferredColorScheme(scheme)
        } else {
            lab
        }
    }

    private var list: PagedList<PagedLabItem, AnyView, AnyView> {
        PagedList(model) { [direction] item in
            direction == .up ? AnyView(PagedLabBubble(item: item)) : AnyView(PagedLabRow(item: item))
        } empty: {
            AnyView(ContentUnavailableView("Nothing Here Yet", systemImage: "tray", description: Text("New items show here.")))
        }
        .pagedSwipeActions { [source] item in
            [PagedListAction("Archive", systemImage: "archivebox", tint: .indigo, removesRow: true) { source.remove(item.id) }]
        }
        .pagedEndLabel(direction == .up ? "Beginning of the conversation" : "You're all caught up")
        .pagedIdentifier("lab.list")
        .pagedProbe(probe)
        .pagedNewestIndicator { [direction] newest in PagedListNewestPill(newest, direction: direction) }
    }

    private var lab: some View {
        NavigationStack {
            Group {
                if direction == .up {
                    // The chat's bottom stack rides the keyboard on a bar that reaches the screen's
                    // bottom edge; the rows ride it.
                    list.pagedBottomAccessory(background: .bar) { bottomStack }
                } else {
                    // A clean screenshot has nothing under the rows: no bar either.
                    list.safeAreaInset(edge: .bottom, spacing: 0) { bottomStack.background(clean ? AnyShapeStyle(.clear) : AnyShapeStyle(.bar)) }
                }
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                if banner {
                    Text("Updating…")
                        .font(theme.type.meta)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(.bar)
                        .accessibilityIdentifier("lab.banner")
                }
            }
            .background(theme.colors.bg.color.ignoresSafeArea())
            .navigationTitle(direction == .up ? "Chat" : "Feed")
            .navigationBarTitleDisplayMode(.inline)
        }
        .preferredColorScheme(scheme)
        .task {
            probe.pageLanded = { [hud] shift, rows in hud.landed(shift: shift, rows: rows) }
            probe.scrolling = { [hud] moving in hud.scrolling(moving) }
            probe.frameShift = { [hud] shift in hud.sampled(shift) }
            probe.passFrameShift = { [hud] shift, mid, detail in hud.passSampled(shift, midPlacement: mid, detail: detail) }
            probe.samplerCost = { [hud] ms in hud.samplerCost(ms) }
            probe.drawnShift = { [hud] shift, detail in hud.drawnSampled(shift, detail) }
            probe.neighbourShift = { [hud] shift, detail in hud.neighbourSampled(shift, detail) }
            probe.shiftDetail = { [hud] shift, detail in hud.shifted(shift, detail) }
            probe.slid = { [hud] frames in hud.slid(frames) }
            probe.held = { [hud] rows in hud.hold(rows) }
            await model.loadFirst()
        }
        .task { await model.listen() }
        .task {
            // The memory the model holds, twice a second (the bench reads it from the HUD).
            while !Task.isCancelled {
                hud.inMemory = model.valuesInMemory
                hud.total = model.total
                model.spillStats { [hud] onDisk, _, bytes in
                    hud.onDisk = onDisk
                    hud.diskBytes = bytes
                }
                // motion: not an animation; the HUD's memory line refreshes twice a second.
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
        .task {
            guard scenario == .live else { return }
            while !Task.isCancelled {
                // motion: not an animation; the lab's live source sends a row every 1.5 s.
                try? await Task.sleep(for: .seconds(1.5))
                source.insertNewest()
            }
        }
    }

    /// The measurement line, the changes a test makes, and (for a chat) the composer.
    private var bottomStack: some View {
        VStack(spacing: 0) {
            if !clean, stress == nil { operations }
            if !clean { hudLine }
            if direction == .up { composer }
        }
    }

    /// Changes a test makes while the reader holds still mid-list; none may move a row on screen
    /// (UITests `test*KeepsTheReaderThrough*`). "The reading row" is the probe's: the first row under
    /// the list's top edge. Each goes through the source, as a backend's change would.
    private var operations: some View {
        HStack(spacing: 4) {
            operation("Remove", "remove") {
                if let id = probe.readingID?.base as? Int { source.remove(id) }
            }
            operation("Move", "move") {
                if let id = probe.readingID?.base as? Int { source.moveToNewest(id) }
            }
            operation("Grow", "grow") {
                let items = model.items
                if let id = probe.readingID?.base as? Int, let index = items.firstIndex(where: { $0.id == id }), index > 0 {
                    source.grow(items[index - 1].id)
                }
            }
            operation("Insert", "insert") { source.insertNewest() }
            // A newest row 2.5 s from now: a test rests a finger on the list before it lands.
            operation("Later", "later") {
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(2.5))
                    source.insertNewest()
                }
            }
            operation("Banner", "banner") { banner.toggle() }
            operation("Reload", "reload") { Task { await model.loadFirst() } }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("lab.ops")
    }

    private func operation(_ title: String, _ id: String, _ action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .font(theme.type.meta)
            .lineLimit(1)
            .buttonStyle(.cmuxPressFill)
            .frame(maxWidth: .infinity)
            .accessibilityIdentifier("lab.op.\(id)")
    }

    private var hudLine: some View {
        // One line at any text size: a line that wraps would move the list's bottom edge.
        Text(hud.line)
            .font(theme.type.meta)
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.4)
            .foregroundStyle(theme.colors.label2.color)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
            .accessibilityIdentifier("lab.hud")
            .accessibilityValue(hud.json(edge: edgeName, newer: newerEdgeName, changes: model.changesApplied, flushes: model.flushes))
    }

    private var edgeName: String { Self.name(model.edge) }
    private var newerEdgeName: String { Self.name(model.newerEdge) }

    private static func name(_ edge: PagedListEdge) -> String {
        switch edge {
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
                source.insertNewest(mine: true, text: draft.isEmpty ? nil : draft)
                draft = ""
            }
            .buttonStyle(.cmuxPressFill)
            .accessibilityIdentifier("lab.send")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

enum PagedLabScenario: String, Sendable {
    /// `stall`: the first page at once, then a read that never answers while a test looks at it
    /// (the edge's spinner, reached in one or two flings).
    case normal, slow, fast, end, empty, firstfail, morefail, live, stall

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
        case .slow: .seconds(6)
        case .fast: .milliseconds(50)
        default: .milliseconds(400)
        }
    }
}

/// One generated row: its number (0 is the newest; live rows are negative), 1 to 5 lines of text.
struct PagedLabItem: Identifiable, Equatable, Sendable, Codable {
    let id: Int
    let mine: Bool
    let text: String
    /// The row's text stands aside for a typing bubble (the stress bench's `typing` load).
    var typing = false

    init(id: Int, mine: Bool? = nil, text: String? = nil, typing: Bool = false) {
        self.id = id
        self.typing = typing
        self.mine = mine ?? (abs(id) % 3 == 0)
        let words = ["the", "list", "keeps", "what", "you", "read", "in", "place", "while", "older", "pages", "land",
                     "above", "and", "below", "with", "no", "jump", "flicker", "or", "hitch"]
        let count = 4 + (abs(id) * 7 % 5) * 9
        self.text = text ?? (0..<count).map { words[(abs(id) + $0 * 3) % words.count] }.joined(separator: " ")
    }
}

/// The lab's paged source: generated rows after a fixed delay, failing where the scenario says, and
/// the lab's edits (remove, move, grow, insert, send), which it applies to its own rows and sends as
/// changes. Pages are the scenario's generated pages (row `n` is in page `n / 30`) in the rows'
/// current order; the first page also holds every row that was moved or sent to the newest end.
@MainActor
final class PagedLabSource: PagedListSource {
    typealias Item = PagedLabItem

    let scenario: PagedLabScenario
    private var failedFirst = false
    private var failedMore = false
    /// Every row, newest first, and the values the lab changed.
    private var order: [Int]
    private var edited: [Int: PagedLabItem] = [:]
    private var nextLive = -1
    /// Rows the composer sends: -1001, -1002, ... (a test finds the first one by name).
    private var nextSent = -1000
    private var continuation: AsyncStream<[PagedListChange<PagedLabItem>]>.Continuation?

    init(scenario: PagedLabScenario) {
        self.scenario = scenario
        order = Array(0..<(scenario.pageSize * scenario.pages))
    }

    struct Failure: LocalizedError {
        var errorDescription: String? { "The lab's source failed on purpose." }
    }

    private func value(_ id: Int) -> PagedLabItem { edited[id] ?? PagedLabItem(id: id) }

    func page(after cursor: String?) async throws -> PagedListPage<PagedLabItem> {
        // motion: not an animation; the lab's source answers after a network-like delay.
        try await Task.sleep(for: scenario == .stall && cursor != nil ? .seconds(600) : scenario.latency)
        let page = cursor.flatMap(Int.init) ?? 0
        if scenario == .firstfail, cursor == nil, !failedFirst {
            failedFirst = true
            throw Failure()
        }
        if scenario == .morefail, page == 1, !failedMore {
            failedMore = true
            throw Failure()
        }
        let size = scenario.pageSize
        let ids: [Int]
        if page == 0 {
            // Through the last row of the first generated page that is still in it.
            let last = order.lastIndex { $0 >= 0 && $0 < size }
            ids = last.map { Array(order[...$0]) } ?? order.filter { $0 < 0 }
        } else {
            ids = order.filter { $0 >= page * size && $0 < (page + 1) * size }
        }
        let next = page + 1 < scenario.pages ? String(page + 1) : nil
        return PagedListPage(items: ids.map(value), nextCursor: next)
    }

    func changes() -> AsyncStream<[PagedListChange<PagedLabItem>]> {
        AsyncStream { continuation in self.continuation = continuation }
    }

    func remove(_ id: Int) {
        order.removeAll { $0 == id }
        continuation?.yield([.remove([id])])
    }

    func moveToNewest(_ id: Int) {
        guard let at = order.firstIndex(of: id) else { return }
        order.remove(at: at)
        order.insert(id, at: 0)
        continuation?.yield([.move(id, after: nil)])
    }

    func grow(_ id: Int) {
        let old = value(id)
        let grown = PagedLabItem(id: id, mine: old.mine, text: old.text + " and then it grew by three more lines of text that wrap")
        edited[id] = grown
        continuation?.yield([.update([grown])])
    }

    func insertNewest(mine: Bool? = nil, text: String? = nil) {
        let id: Int
        if mine == true {
            nextSent -= 1
            id = nextSent
        } else {
            nextLive -= 1
            id = nextLive
        }
        let item = PagedLabItem(id: id, mine: mine, text: text)
        edited[item.id] = item
        order.insert(item.id, at: 0)
        continuation?.yield([.newest([item])])
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
    /// The largest move of the row being read, in any frame, that the scroll itself doesn't explain
    /// (the probe's per-frame layout shift; while scrolling too).
    var frameShift: CGFloat = 0
    /// What the list was doing in the worst shifted frame (the controller's probe detail).
    var worstShift = ""
    /// Layout passes the measure sampled, and those whose shift passed half a point.
    var samples = 0
    var shiftedFrames = 0
    /// The same measure at each layout pass (the probe's `passFrameShift`), kept beside the committed
    /// frames' so a run shows what moved from counted to not counted: its worst, its shifted samples,
    /// those taken while the list was mid-placement, and the worst one's detail.
    var passFrameShift: CGFloat = 0
    var passShifted = 0
    var passMidPlacement = 0
    var passWorstShift = ""
    /// The committed-frame measure's own time per drawn frame (ms): all samples, kept for the mean and p99.
    @ObservationIgnored var samplerCosts: [Double] = []
    /// Slides to the newest end, and the display frames the last one took (1: a jump).
    var slides = 0
    var slideFrames = 0
    /// Rows that arrived under a resting finger and waited for it.
    var heldRows = 0
    /// Row values in memory, rows known, rows on disk and the disk file's size.
    var inMemory = 0
    var total = 0
    var onDisk = 0
    var diskBytes = 0
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

    func sampled(_ shift: CGFloat) {
        samples += 1
        if abs(shift) > 0.5 { shiftedFrames += 1 }
        if abs(shift) > frameShift { frameShift = abs(shift) }
    }

    /// The drawn measure: the worst drawn shift beyond the scroll, how many frames drew one over half
    /// a point, and the worst one's detail.
    var drawnShift: CGFloat = 0
    var drawnShifted = 0
    var drawnWorst = ""

    /// The neighbour measure: the rows around the eye line (``PagedListProbe/neighbourShift``).
    @ObservationIgnored var neighbourShift: CGFloat = 0
    @ObservationIgnored var neighbourShifted = 0
    @ObservationIgnored var neighbourWorst = ""

    func neighbourSampled(_ shift: CGFloat, _ detail: String?) {
        guard abs(shift) > 0.5 else { return }
        neighbourShifted += 1
        if abs(shift) > neighbourShift {
            neighbourShift = abs(shift)
            neighbourWorst = detail ?? ""
        }
    }

    func drawnSampled(_ shift: CGFloat, _ detail: String?) {
        guard abs(shift) > 0.5 else { return }
        drawnShifted += 1
        if abs(shift) > drawnShift {
            drawnShift = abs(shift)
            drawnWorst = detail ?? ""
        }
    }

    func samplerCost(_ ms: Double) {
        samplerCosts.append(ms)
    }

    func passSampled(_ shift: CGFloat, midPlacement: Bool, detail: String?) {
        guard abs(shift) > 0.5 else { return }
        passShifted += 1
        if midPlacement { passMidPlacement += 1 }
        if abs(shift) >= passFrameShift {
            passFrameShift = abs(shift)
            passWorstShift = "mid=\(midPlacement) " + (detail ?? "")
        }
    }

    func shifted(_ shift: CGFloat, _ detail: String) {
        if abs(shift) >= frameShift { worstShift = detail }
    }

    func slid(_ frames: Int) {
        slides += 1
        slideFrames = frames
    }

    func hold(_ rows: Int) {
        heldRows += rows
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

    func json(edge: String, newer: String = "end", changes: Int = 0, flushes: Int = 0) -> String {
        let ratio = seconds > 0 ? hitchMs / seconds : 0
        let samplerMean = samplerCosts.isEmpty ? 0 : samplerCosts.reduce(0, +) / Double(samplerCosts.count)
        let samplerP99 = samplerCosts.isEmpty ? 0 : samplerCosts.sorted()[min(samplerCosts.count - 1, samplerCosts.count * 99 / 100)]
        return #"{"edge":"\#(edge)","newer":"\#(newer)","rows":\#(rows),"landings":\#(landings),"maxShift":\#(maxShift),"frameShift":\#(frameShift),"samples":\#(samples),"shiftedFrames":\#(shiftedFrames),"frames":\#(frames),"hitches":\#(hitches),"dropped":\#(dropped),"worstMs":\#(worstMs),"hitchMsPerS":\#(ratio),"changes":\#(changes),"flushes":\#(flushes),"inMemory":\#(inMemory),"total":\#(total),"onDisk":\#(onDisk),"diskBytes":\#(diskBytes),"slides":\#(slides),"slideFrames":\#(slideFrames),"held":\#(heldRows),"worstShift":"\#(worstShift)","passFrameShift":\#(passFrameShift),"passShifted":\#(passShifted),"passMidPlacement":\#(passMidPlacement),"passWorstShift":"\#(passWorstShift)","samplerMeanMs":\#(samplerMean),"samplerP99Ms":\#(samplerP99),"samplerFrames":\#(samplerCosts.count),"drawnShift":\#(drawnShift),"drawnShifted":\#(drawnShifted),"drawnWorst":"\#(drawnWorst)","neighbourShift":\#(neighbourShift),"neighbourShifted":\#(neighbourShifted),"neighbourWorst":"\#(neighbourWorst)"}"#
    }
}

struct PagedLabRow: View {
    let item: PagedLabItem

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Item \(item.id)")
                .font(theme.type.rowTitle)
                .foregroundStyle(theme.colors.label.color)
            if item.typing {
                PagedLabTypingBubble()
            } else {
                Text(item.text)
                    .font(theme.type.rowSubtitle)
                    .foregroundStyle(theme.colors.label2.color)
            }
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

/// A short typing bubble in place of a row's text: a fixed-height capsule around a UIKit view, as
/// Home's typing bubble is (a row's height changes on reconfigure, and part of it is a UIKit view).
struct PagedLabTypingBubble: View {
    var body: some View {
        PagedLabTypingDots()
            .frame(width: 34, height: 8)
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(theme.colors.surfaceRaised.color, in: .capsule)
            .accessibilityLabel("Typing")
    }
}

private struct PagedLabTypingDots: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .secondaryLabel
        view.layer.cornerRadius = 4
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {}
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
