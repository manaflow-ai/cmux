#if os(iOS)
import CmuxMobileDesign
import SwiftUI
import UIKit

/// A static, bottom-aligned rendering of the newest turns: what the chat
/// looks like at rest, for tab grid cards and swipe neighbors. No scroll
/// view, no bindings, no demo commands.
public struct AgentChatPreview: View {
    let store: AgentChatStore
    /// The turns to draw (the last ones); nil reads the store's own. A grid
    /// card passes a copy it updates only while the grid shows and is not
    /// scrolling, so a streaming chat does not re-render its card per token.
    var turns: [AgentTurn]?
    var topInset: CGFloat
    var bottomInset: CGFloat
    @State private var model = AgentChatPreviewModel()

    public init(store: AgentChatStore, turns: [AgentTurn]? = nil, topInset: CGFloat, bottomInset: CGFloat) {
        self.store = store
        self.turns = turns
        self.topInset = topInset
        self.bottomInset = bottomInset
    }

    /// Whether a still of these turns (a tab card's picture, drawn with no `.task`) can show
    /// what their rows load first: their sent images' thumbnails. Starts what is missing and is
    /// observed, so a caller reads it again when it lands.
    public static func picturesReady(_ turns: [AgentTurn]) -> Bool {
        SentAttachmentThumbnails.shared.ready(turns)
    }

    /// Whether those thumbnails are in memory now, to draw the still; decodes again any the
    /// cache let go since (`SentAttachmentThumbnails.resident`). Not observed.
    public static func picturesResident(_ turns: [AgentTurn]) -> Bool {
        SentAttachmentThumbnails.shared.resident(turns)
    }

    /// The thumbnails a still being drawn holds, so the cache's bound cannot let one go between
    /// the check and the draw, or while the still waits for another (`picturesResident(_:holding:)`).
    @MainActor
    public final class PictureHold {
        let thumbnails = SentAttachmentHold()
        public init() {}
    }

    /// `picturesResident(_:)` for a still that waits: the thumbnails found in memory, or decoded
    /// for it since, are kept in `hold`, and count as in memory on the next call even if the cache
    /// let them go.
    public static func picturesResident(_ turns: [AgentTurn], holding hold: PictureHold) -> Bool {
        SentAttachmentThumbnails.shared.resident(turns, holding: hold.thumbnails)
    }

    /// Draws a still (`draw`, synchronous) with `hold`'s thumbnails readable by its bubbles.
    public static func drawing<T>(_ hold: PictureHold, _ draw: () -> T) -> T {
        SentAttachmentThumbnails.shared.drawing(hold.thumbnails, draw)
    }

    public var body: some View {
        // Laid out as the live page at rest (`ChatTranscriptController`), so a card opens into
        // its page without a jump: the rows bottom aligned on the composer's gap
        // (`bottomInset`, `AgentChatSurface.restingTranscriptBottomInset`), the overflow
        // clipped at the top, in the chat's own Text and Width; with no turns, the page's empty
        // state centered between the header and the composer.
        let display = ChatDisplayPreferences.shared.settings(for: store.summary)
        Color.cmuxMobileBackground
            .overlay(alignment: .bottom) {
                if isEmpty {
                    AgentChatEmptyState(store: store)
                        .padding(.horizontal, 20)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .padding(.top, topInset)
                        .padding(.bottom, max(0, bottomInset - ChatTranscriptController.contentGap))
                } else {
                    rows
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 20)
                        // The column's cap (Text and Width's standard width), as the transcript's.
                        .frame(maxWidth: display.fullWidth ? .infinity : ChatDisplaySettings.standardColumn + 40)
                        .padding(.bottom, bottomInset)
                }
            }
            .modifier(ChatTextSize(display: display))
            .clipped()
            .allowsHitTesting(false)
            // Its rows draw their UIKit controls' stand-ins (`chatStill`): a tab card's picture
            // is an `ImageRenderer` still of this view.
            .environment(\.chatStill, true)
    }

    private var isEmpty: Bool { turns.map(\.isEmpty) ?? !store.hasTurns }

    private var rows: some View {
        let rows = model.tail(of: store, turns: turns)
        return PreviewRows(rows: rows, context: model.context(store))
            .padding(.bottom, ChatTranscriptBuilder.trailingGap(after: rows.last))
    }
}

/// The card's rows, stacked as the transcript stacks them (`ChatTranscriptLayout`): each row
/// `gap` below the one before, a row the transcript draws natively (`ChatNativeEligibility`)
/// at its native layout's height, the rest at their SwiftUI height. The card draws every row
/// in SwiftUI (a picture cannot hold UIKit cells), so its rows take the live list's heights.
private struct PreviewRows: View {
    let rows: [ChatRow]
    let context: ChatRowContext
    @Environment(\.dynamicTypeSize) private var textSize

    var body: some View {
        PreviewColumn(rows: rows, category: UIContentSizeCategory(textSize), wrapCode: CmuxMobilePreferences.wrapCode()) {
            ForEach(rows) { row in
                ChatRowView(row: row, context: context)
                    .modifier(PreviewRowProbe(id: row.id))
            }
        }
    }
}

struct PreviewColumn: Layout {
    let rows: [ChatRow]
    let category: UIContentSizeCategory
    let wrapCode: Bool

    struct Cache {
        var width: CGFloat = -1
        var heights: [CGFloat] = []
    }

    func makeCache(subviews: Subviews) -> Cache { Cache() }
    func updateCache(_ cache: inout Cache, subviews: Subviews) { cache = Cache() }

    /// A row's height in a column `width` wide (its 20 pt margins already out), as the live
    /// list lays it out: its native layout's when it draws natively at rest.
    private func heights(width: CGFloat, subviews: Subviews, cache: inout Cache) -> [CGFloat] {
        if cache.width == width, cache.heights.count == subviews.count { return cache.heights }
        let environment = ChatNativeEnvironment(width: width, category: category, wrapCode: wrapCode)
        let heights = zip(rows, subviews).map { row, subview -> CGFloat in
            if ChatNativeEligibility.drawsNatively(row, accessibilitySize: category.isAccessibilityCategory, wrapCode: wrapCode, isOpen: { _ in nil }),
               let native = ChatNativeLayout.make(row.kind, id: row.id, expanded: false, environment: environment) {
                return native.height
            }
            return subview.sizeThatFits(ProposedViewSize(width: width, height: nil)).height
        }
        cache = Cache(width: width, heights: heights)
        return heights
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize {
        let width = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? 0
        let heights = heights(width: width, subviews: subviews, cache: &cache)
        let total = zip(rows, heights).reduce(CGFloat(0)) { $0 + CGFloat($1.0.gap) + $1.1 }
        return CGSize(width: width, height: total)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) {
        let heights = heights(width: bounds.width, subviews: subviews, cache: &cache)
        var y = bounds.minY
        for (index, subview) in subviews.enumerated() where index < rows.count {
            y += CGFloat(rows[index].gap)
            // At its own height, pinned to its slot's top (as `ChatRowTop` pins a hosted row).
            subview.place(at: CGPoint(x: bounds.minX, y: y), anchor: .topLeading,
                          proposal: ProposedViewSize(width: bounds.width, height: nil))
            y += heights[index]
        }
    }
}

/// A chat's Text and Width text size over the person's own (`ChatDisplaySettings.category`),
/// as the live transcript's trait override (`ChatTranscriptController.applyDisplay`).
struct ChatTextSize: ViewModifier {
    let display: ChatDisplaySettings
    @Environment(\.dynamicTypeSize) private var system

    func body(content: Content) -> some View {
        if let category = display.category(system: UIContentSizeCategory(system)), let size = DynamicTypeSize(category) {
            content.environment(\.dynamicTypeSize, size)
        } else {
            content
        }
    }
}

/// Tests: each preview row's frame in window space (`AgentCardOpenGeometryTests` compares it with
/// the live transcript's row at the same page size). Nothing is attached while no probe is set.
struct PreviewRowProbe: ViewModifier {
    let id: String
    #if DEBUG
    @MainActor static var report: (@MainActor (String, CGRect) -> Void)?
    #endif

    func body(content: Content) -> some View {
        #if DEBUG
        if let report = Self.report {
            content.onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }) { report(id, $0) }
        } else {
            content
        }
        #else
        content
        #endif
    }
}

extension EnvironmentValues {
    /// The rows are drawn as a still (a tab card's picture, `AgentCardRasterizer`, or the live
    /// preview that stands in until it is drawn). `ImageRenderer` draws only SwiftUI's own views:
    /// a control UIKit draws (`Menu`, `ShareLink`, a text field) comes out as its yellow "can't
    /// render" placeholder (Leo, 2026-11-17: "Weird placeholder for retries esp in preview", the
    /// error card's Retry with another model). A row reads this and draws that control's label
    /// as plain SwiftUI instead, at the same size, so the still looks like the live chat.
    @Entry var chatStill = false
}

/// The card's rows: the transcript's rows (memoized per turn, an answer parsed by its
/// tail), cut to what a bottom-aligned card can show. The card stays alive beside the
/// live page, so drawing the whole chat laid out every streamed answer in full (its
/// tables and code) on every frame.
@MainActor
final class AgentChatPreviewModel {
    /// More than a page of estimated height: rows above it are clipped off the card.
    static let budget: CGFloat = 2400
    private var builder: ChatTranscriptBuilder?
    private var rowContext: ChatRowContext?

    func context(_ store: AgentChatStore) -> ChatRowContext {
        if let rowContext, rowContext.store === store { return rowContext }
        let context = ChatRowContext(store: store, surface: AgentChatSurface())
        rowContext = context
        return context
    }

    /// `frozen`: the turns a grid card holds (it updates them only while the grid rests); nil reads the store's.
    func tail(of store: AgentChatStore, turns frozen: [AgentTurn]? = nil) -> [ChatRow] {
        if builder?.diffs !== store.diffs { builder = ChatTranscriptBuilder(diffs: store.diffs) }
        guard let builder else { return [] }
        let turns = frozen ?? store.turns
        // The newest turns that fill the page, as the page shows them: two newest turns shorter
        // than the page left the card's top blank where the page shows older turns (the part
        // of the page a card shows is its top). More turns are taken until the rows fill the
        // budget or the chat begins.
        var count = min(2, turns.count)
        while true {
            let shown = Array(turns.suffix(count))
            let built = builder.build(turns: shown, pendingPermission: store.pendingPermission,
                                      askOpen: store.pendingPermission != nil || store.pendingQuestion != nil, permissionBarHidden: false,
                                      earlierHistory: count >= turns.count && store.hasEarlierHistory,
                                      dismissedWrapUps: WrapUpDismissals.shared.dismissedTurns(in: store.summary))
            var out: [ChatRow] = []
            var height: CGFloat = 0
            var filled = false
            for row in built.flatMap(\.rows).reversed() {
                // The session line belongs to the chat's first turn only.
                if row.id == "session-start", count < turns.count { continue }
                out.append(row)
                height += row.gap + row.estimatedHeight(width: 350)
                if height > Self.budget { filled = true; break }
            }
            if filled || count >= turns.count { return out.reversed() }
            count = min(turns.count, count * 2)
        }
    }
}
#endif
