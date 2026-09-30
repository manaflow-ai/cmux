import AppKit
import CmuxAcpmux

/// Identifies one row layout: row id, content version, width, group position and expansion.
struct AcpmuxRowLayoutKey: Hashable, Sendable {
    let id: String
    let version: Int
    let width: Int
    let position: AcpmuxRowGroupPosition
    let expanded: Bool
}

/// A request to lay out one row off the main thread.
struct AcpmuxRowLayoutRequest: Sendable {
    let key: AcpmuxRowLayoutKey
    let row: TranscriptRow
    let width: CGFloat
}

/// Computes and caches ``AcpmuxRowLayout``s so scrolling and unrelated updates never
/// re-measure.
///
/// Text is laid out off the main thread by a small worker pool: rows about to scroll into
/// view first (``prefetch(_:)``), then every other row in the background
/// (``layOutInBackground(_:)``), which records only heights. A cell then only adopts a
/// finished layout. The main thread lays text out itself only for a row that must show
/// before its layout is ready, such as the streaming answer, whose growth has to land in
/// the frame it arrives.
///
/// Heights are kept for every row; finished layouts (TextKit groups, tens of kilobytes
/// each) only for the rows used most recently, so a long transcript stays small.
@MainActor
final class AcpmuxRowLayoutEngine {
    private(set) var builder: AcpmuxRowLayoutBuilder
    private var cache: [AcpmuxRowLayoutKey: AcpmuxRowLayout] = [:]
    private var lastUse: [AcpmuxRowLayoutKey: Int] = [:]
    private var useClock = 0
    private var heights: [AcpmuxRowLayoutKey: CGFloat] = [:]
    /// About ten screens of rows; prefetch refills what scrolling needs.
    private let layoutLimit = 400
    /// The most recent measurement of each row at any width, for cheap estimates during resize.
    private var lastMeasured: [String: (version: Int, width: CGFloat, height: CGFloat)] = [:]
    /// Bumped when cached layouts become invalid (theme change), so results from requests
    /// started earlier are dropped.
    private var generation = 0
    private var urgentQueue: [AcpmuxRowLayoutRequest] = []
    private var backgroundQueue: [AcpmuxRowLayoutRequest] = []
    private var backgroundHead = 0
    private var inFlight = Set<AcpmuxRowLayoutKey>()
    private var workers = 0
    private let maxWorkers = max(2, min(4, ProcessInfo.processInfo.activeProcessorCount - 2))
    /// Called on the main thread after background layouts land in the cache.
    var onLayoutsReady: ((_ rowIDs: [String]) -> Void)?
    /// Rows the main thread laid out itself because no finished layout was ready.
    private(set) var synchronousLayoutCount = 0

    static let sideInset = AcpmuxRowLayoutBuilder.sideInset
    static let bubbleHorizontalPadding = AcpmuxRowLayoutBuilder.bubbleHorizontalPadding
    static let bubbleVerticalPadding = AcpmuxRowLayoutBuilder.bubbleVerticalPadding
    static let typingSize = AcpmuxRowLayoutBuilder.typingSize

    init(theme: AcpmuxChatTheme) {
        builder = AcpmuxRowLayoutBuilder(theme: theme)
    }

    var theme: AcpmuxChatTheme { builder.renderer.theme }

    func setTheme(_ theme: AcpmuxChatTheme) {
        guard theme != builder.renderer.theme else { return }
        builder = AcpmuxRowLayoutBuilder(theme: theme)
        generation += 1
        cache.removeAll()
        lastUse.removeAll()
        heights.removeAll()
        urgentQueue.removeAll()
        backgroundQueue.removeAll()
        backgroundHead = 0
    }

    /// Drops cached layouts for widths other than `width`, bounding memory during resizes.
    func retainOnly(width: CGFloat) {
        let keep = Int(width.rounded())
        cache = cache.filter { $0.key.width == keep }
        lastUse = lastUse.filter { $0.key.width == keep }
        heights = heights.filter { $0.key.width == keep }
    }

    static func key(for row: TranscriptRow, position: AcpmuxRowGroupPosition, width: CGFloat, expanded: Bool) -> AcpmuxRowLayoutKey {
        AcpmuxRowLayoutKey(id: row.id, version: row.version, width: Int(width.rounded()), position: position, expanded: expanded)
    }

    /// The layout, from the cache or laid out now on the main thread.
    func layout(for row: TranscriptRow, position: AcpmuxRowGroupPosition, width: CGFloat, expanded: Bool) -> AcpmuxRowLayout {
        let key = Self.key(for: row, position: position, width: width, expanded: expanded)
        useClock += 1
        if let cached = cache[key] {
            lastUse[key] = useClock
            return cached
        }
        synchronousLayoutCount += 1
        let computed = builder.layout(for: row, position: position, width: width, expanded: expanded)
        store(computed, for: key, rowID: row.id, width: width, keepsLayout: true)
        return computed
    }

    /// Whether a finished layout for this row is cached.
    func hasLayout(for key: AcpmuxRowLayoutKey) -> Bool { cache[key] != nil }

    /// Whether this row's exact height is known.
    func hasHeight(for key: AcpmuxRowLayoutKey) -> Bool { heights[key] != nil }

    private func store(_ layout: AcpmuxRowLayout, for key: AcpmuxRowLayoutKey, rowID: String, width: CGFloat, keepsLayout: Bool) {
        heights[key] = layout.height
        lastMeasured[rowID] = (key.version, width, layout.height)
        guard keepsLayout else { return }
        useClock += 1
        cache[key] = layout
        lastUse[key] = useClock
        if cache.count > layoutLimit + layoutLimit / 4 { evictLeastRecentlyUsed() }
    }

    /// Drops the least recently used layouts down to the limit. A cell that shows one keeps
    /// it alive; it is laid out again only if it scrolls back into view after that.
    private func evictLeastRecentlyUsed() {
        let evicted = lastUse.sorted { $0.value < $1.value }.prefix(cache.count - layoutLimit)
        for (key, _) in evicted {
            cache[key] = nil
            lastUse[key] = nil
        }
    }

    /// The height at `width` without laying out: the exact cached height when there is one,
    /// otherwise an estimate scaled from the row's last measurement (text reflows roughly in
    /// inverse proportion to width), or a character-count guess for a row never measured.
    /// Returns `nil` only for a zero width.
    func height(for row: TranscriptRow, position: AcpmuxRowGroupPosition, width: CGFloat, expanded: Bool) -> (height: CGFloat, exact: Bool)? {
        let key = Self.key(for: row, position: position, width: width, expanded: expanded)
        if let exact = heights[key] { return (exact, true) }
        guard width > 0 else { return nil }
        guard let last = lastMeasured[row.id], last.version == row.version else {
            return (builder.roughHeight(for: row, width: width), false)
        }
        let scale = min(3, max(0.5, last.width / width))
        return (max(24, (last.height * scale).rounded()), false)
    }

    // MARK: - Background layout

    /// Lays out rows about to scroll into view ahead of everything else. A new call
    /// replaces the previous urgent set, which the viewport has moved past.
    func prefetch(_ requests: [AcpmuxRowLayoutRequest]) {
        urgentQueue = requests.filter { cache[$0.key] == nil && !inFlight.contains($0.key) }
        startWorkersIfNeeded()
    }

    /// Sets the rows for low-priority layout, after any urgent rows. The transcript passes
    /// every row whose height is still an estimate, so the list replaces the previous one
    /// (for example, one queued at a width the pane has since left).
    func layOutInBackground(_ requests: [AcpmuxRowLayoutRequest]) {
        backgroundQueue = requests.filter { heights[$0.key] == nil }
        backgroundHead = 0
        startWorkersIfNeeded()
    }

    private var hasQueuedWork: Bool { !urgentQueue.isEmpty || backgroundHead < backgroundQueue.count }

    private func startWorkersIfNeeded() {
        while workers < maxWorkers, hasQueuedWork {
            workers += 1
            Task.detached(priority: .userInitiated) { [weak self] in
                while let work = await self?.takeBatch() {
                    let results = work.requests.map { request in
                        (request, work.builder.layout(
                            for: request.row,
                            position: request.key.position,
                            width: request.width,
                            expanded: request.key.expanded
                        ))
                    }
                    await self?.finish(results, generation: work.generation, keepsLayouts: work.keepsLayouts)
                }
            }
        }
    }

    private struct Batch: Sendable {
        let generation: Int
        let builder: AcpmuxRowLayoutBuilder
        let requests: [AcpmuxRowLayoutRequest]
        /// Prefetched rows keep their layouts for display; background rows keep only heights.
        let keepsLayouts: Bool
    }

    /// The next few requests for a worker, urgent ones first, or `nil` to stop the worker.
    private func takeBatch() -> Batch? {
        var batch: [AcpmuxRowLayoutRequest] = []
        let urgent = !urgentQueue.isEmpty
        while batch.count < (urgent ? 4 : 16), let request = urgent ? nextUrgent() : nextBackground() {
            let done = urgent ? cache[request.key] != nil : heights[request.key] != nil
            guard !done, !inFlight.contains(request.key) else { continue }
            inFlight.insert(request.key)
            batch.append(request)
        }
        guard !batch.isEmpty else {
            if hasQueuedWork { return takeBatch() }
            workers -= 1
            return nil
        }
        return Batch(generation: generation, builder: builder, requests: batch, keepsLayouts: urgent)
    }

    private func nextUrgent() -> AcpmuxRowLayoutRequest? {
        urgentQueue.isEmpty ? nil : urgentQueue.removeFirst()
    }

    private func nextBackground() -> AcpmuxRowLayoutRequest? {
        guard backgroundHead < backgroundQueue.count else { return nil }
        defer { backgroundHead += 1 }
        return backgroundQueue[backgroundHead]
    }

    private func finish(_ results: [(AcpmuxRowLayoutRequest, AcpmuxRowLayout)], generation: Int, keepsLayouts: Bool) {
        for (request, _) in results { inFlight.remove(request.key) }
        guard generation == self.generation else { return }
        for (request, layout) in results where cache[request.key] == nil {
            store(layout, for: request.key, rowID: request.row.id, width: request.width, keepsLayout: keepsLayouts)
        }
        onLayoutsReady?(results.map { $0.0.row.id })
    }
}

/// Builds row layouts. It holds only immutable values, so any thread can use it.
struct AcpmuxRowLayoutBuilder: @unchecked Sendable {
    let renderer: AcpmuxChatTextRenderer
    private let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter
    }()

    static let sideInset: CGFloat = 16
    static let bubbleHorizontalPadding: CGFloat = 12
    static let bubbleVerticalPadding: CGFloat = 7.5
    static let typingSize = CGSize(width: 58, height: 34)

    init(theme: AcpmuxChatTheme) {
        renderer = AcpmuxChatTextRenderer(theme: theme)
    }

    func layout(for row: TranscriptRow, position: AcpmuxRowGroupPosition, width: CGFloat, expanded: Bool) -> AcpmuxRowLayout {
        var computed = compute(row, position: position, width: max(width, 120), expanded: expanded)
        computed.surfacePath = surfacePath(for: computed, position: position)
        return computed
    }

    /// A cheap height guess for a row never measured, from its character count; the
    /// transcript replaces it with the measured height once the row's layout is ready.
    func roughHeight(for row: TranscriptRow, width: CGFloat) -> CGFloat {
        let lineHeight: CGFloat = 19
        func textHeight(_ text: String, bubbleWidth: CGFloat) -> CGFloat {
            let usable = max(80, bubbleWidth - 2 * Self.bubbleHorizontalPadding)
            let charactersPerLine = max(10, usable / 7.4)
            let lines = text.split(separator: "\n", omittingEmptySubsequences: false).reduce(0) { total, line in
                total + max(1, Int((CGFloat(line.count) / charactersPerLine).rounded(.up)))
            }
            return CGFloat(lines) * lineHeight + 2 * Self.bubbleVerticalPadding + 11
        }
        switch row.content {
        case .user(let message): return textHeight(message.text, bubbleWidth: min(width * 0.7, 560))
        case .assistant(let text, _): return textHeight(text, bubbleWidth: min(width * 0.7, 760))
        case .turnSummary: return 42
        case .typing: return 48
        case .activity: return 26
        case .permission: return 26
        case .notice: return 32
        case .plan(let entries): return 40 + CGFloat(entries.count) * 20
        }
    }

    private func surfacePath(for layout: AcpmuxRowLayout, position: AcpmuxRowGroupPosition) -> CGPath? {
        let bubble = AcpmuxBubblePath()
        switch layout.surface {
        case .userBubble, .assistantBubble:
            return bubble.path(
                for: layout.surfaceFrame,
                side: layout.surface == .userBubble ? .trailing : .leading,
                tail: layout.showsTail,
                groupedAbove: !position.isFirst,
                groupedBelow: !position.isLast
            )
        case .typing:
            return bubble.path(for: layout.surfaceFrame, side: .leading, tail: true, groupedAbove: false, groupedBelow: false)
        case .card:
            return AcpmuxBubblePath.card(layout.surfaceFrame, radius: 10)
        case .none:
            return nil
        }
    }

    private func compute(_ row: TranscriptRow, position: AcpmuxRowGroupPosition, width: CGFloat, expanded: Bool) -> AcpmuxRowLayout {
        let side = Self.sideInset
        let timestamp = row.at > 0 ? timeFormatter.string(from: Date(timeIntervalSince1970: TimeInterval(row.at) / 1000)) : nil
        switch row.content {
        case .user(let message):
            let text = renderer.userMessage(message.text)
            // Room on the leading side for the red retry badge of an undelivered message.
            let maxBubble = min(width * 0.7, 560) - (message.failed ? 30 : 0)
            var layout = bubble(text, trailing: true, maxBubble: maxBubble, width: width, position: position,
                                // Messages shows a sending bubble at full color; dimming it made the
                                // morph hand-off pop from the overlay's color to a faded cell.
                                surface: .userBubble, dimmed: false, timestamp: timestamp)
            layout.showsRetry = message.failed
            return layout
        case .assistant(let markdown, _):
            let maxBubble = min(width * 0.7, 760)
            return bubble(renderer.markdown(markdown), trailing: false, maxBubble: maxBubble, width: width,
                          position: position, surface: .assistantBubble, dimmed: false, timestamp: timestamp)
        case .activity(let group):
            return plain(renderer.activity(group, expanded: expanded), width: width, top: 4, bottom: 4,
                         indent: side + 4, toggleable: true, timestamp: timestamp)
        case .plan(let entries):
            return card(renderer.plan(entries), width: width, timestamp: timestamp)
        case .permission(let card):
            return plain(renderer.permission(card), width: width, top: 4, bottom: 4, indent: side + 4,
                         toggleable: false, timestamp: timestamp)
        case .turnSummary(let summary):
            return plain(renderer.turnSummary(summary), width: width, top: 10, bottom: 14, indent: side,
                         toggleable: false, timestamp: timestamp)
        case .notice(let text):
            return plain(renderer.notice(text), width: width, top: 8, bottom: 8, indent: side,
                         toggleable: false, timestamp: timestamp)
        case .typing:
            let top: CGFloat = 8
            let frame = CGRect(origin: CGPoint(x: side, y: top), size: Self.typingSize)
            return AcpmuxRowLayout(height: top + frame.height + 6, surfaceFrame: frame, textFrame: .zero,
                                   textLayout: .empty(), surface: .typing, showsTail: true,
                                   isToggleable: false, dimmed: false, timestamp: nil)
        }
    }

    private func bubble(
        _ text: NSAttributedString,
        trailing: Bool,
        maxBubble: CGFloat,
        width: CGFloat,
        position: AcpmuxRowGroupPosition,
        surface: AcpmuxRowLayout.Surface,
        dimmed: Bool,
        timestamp: String?
    ) -> AcpmuxRowLayout {
        let horizontal = Self.bubbleHorizontalPadding
        let vertical = Self.bubbleVerticalPadding
        let maxText = max(40, maxBubble - 2 * horizontal)
        // The text container's width must equal the text frame's width, so the layout the
        // cell adopts wraps exactly as measured.
        var textLayout = AcpmuxTextLayout(text: text, width: maxText)
        var textSize = CGSize(width: maxText, height: textLayout.usedSize.height)
        // Shrink-wrap to the widest line, then confirm nothing rewraps at that width
        // (code blocks and indents need their insets on top of the used width).
        let wrapWidth = min(maxText, textLayout.usedSize.width + 1)
        if wrapWidth < maxText {
            let rewrapped = AcpmuxTextLayout(text: text, width: wrapWidth)
            if rewrapped.usedSize.height <= textLayout.usedSize.height {
                textLayout = rewrapped
                textSize = CGSize(width: wrapWidth, height: rewrapped.usedSize.height)
            }
        }
        let bubbleWidth = min(maxBubble, textSize.width + 2 * horizontal)
        let bubbleHeight = textSize.height + 2 * vertical
        let top: CGFloat = position.isFirst ? 11 : 2
        let x = trailing ? width - Self.sideInset - bubbleWidth : Self.sideInset
        let frame = CGRect(x: x, y: top, width: bubbleWidth, height: bubbleHeight)
        let textFrame = CGRect(x: frame.minX + horizontal, y: frame.minY + vertical,
                               width: bubbleWidth - 2 * horizontal, height: textSize.height)
        return AcpmuxRowLayout(height: top + bubbleHeight + (position.isLast ? 4 : 0), surfaceFrame: frame,
                               textFrame: textFrame, textLayout: textLayout, surface: surface, showsTail: position.isLast,
                               isToggleable: false, dimmed: dimmed, timestamp: timestamp)
    }

    private func plain(
        _ text: NSAttributedString,
        width: CGFloat,
        top: CGFloat,
        bottom: CGFloat,
        indent: CGFloat,
        toggleable: Bool,
        timestamp: String?
    ) -> AcpmuxRowLayout {
        let available = width - indent - Self.sideInset
        let textLayout = AcpmuxTextLayout(text: text, width: available)
        let size = textLayout.usedSize
        let frame = CGRect(x: indent, y: top, width: available, height: size.height)
        return AcpmuxRowLayout(height: top + size.height + bottom, surfaceFrame: frame, textFrame: frame,
                               textLayout: textLayout, surface: .none, showsTail: false, isToggleable: toggleable,
                               dimmed: false, timestamp: timestamp)
    }

    private func card(_ text: NSAttributedString, width: CGFloat, timestamp: String?) -> AcpmuxRowLayout {
        let side = Self.sideInset
        let padding: CGFloat = 10
        let cardWidth = min(width - 2 * side, 640)
        let textLayout = AcpmuxTextLayout(text: text, width: cardWidth - 2 * padding)
        let size = textLayout.usedSize
        let frame = CGRect(x: side, y: 6, width: cardWidth, height: size.height + 2 * padding)
        return AcpmuxRowLayout(height: frame.maxY + 6, surfaceFrame: frame,
                               textFrame: frame.insetBy(dx: padding, dy: padding), textLayout: textLayout, surface: .card,
                               showsTail: false, isToggleable: false, dimmed: false, timestamp: timestamp)
    }
}
