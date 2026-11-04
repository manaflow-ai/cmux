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
        // Bottom aligned like the transcript at rest in follow mode: the
        // turns keep their natural height and the overflow clips at the top.
        Color.cmuxMobileBackground
            .overlay(alignment: .bottom) {
                content
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 20)
                    .padding(.bottom, bottomInset)
            }
            .overlay(alignment: .top) {
                // The status bar region stays clear, as on the live page.
                Color.clear.frame(height: topInset)
            }
            .clipped()
            .allowsHitTesting(false)
    }

    @ViewBuilder private var content: some View {
        if turns.map(\.isEmpty) ?? !store.hasTurns {
            VStack(spacing: 12) {
                Image(systemName: "sparkle")
                    .font(.system(size: 22))
                    .frame(width: 48, height: 48)
                    .background(Color.cmuxMobileSurfaceRaised, in: .circle)
                Text("What should \(store.summary.agentName) do?").font(.title3.weight(.semibold))
            }
            .frame(maxWidth: .infinity)
            .padding(.bottom, 240)
        } else {
            let rows = model.tail(of: store, turns: turns)
            VStack(alignment: .leading, spacing: 0) {
                ForEach(rows) { row in
                    ChatRowView(row: row, context: model.context(store))
                        .padding(.top, row.gap)
                }
            }
            .padding(.bottom, ChatTranscriptBuilder.trailingGap(after: rows.last))
        }
    }
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
        // The newest two turns, as the card showed before.
        let shown = Array(turns.suffix(2))
        let built = builder.build(turns: shown, pendingPermission: store.pendingPermission,
                                  askOpen: store.pendingPermission != nil || store.pendingQuestion != nil, permissionBarHidden: false)
        var out: [ChatRow] = []
        var height: CGFloat = 0
        for row in built.flatMap(\.rows).reversed() {
            // The session line belongs to the chat's first turn only.
            if row.id == "session-start", turns.count > 2 { continue }
            out.append(row)
            height += row.gap + row.estimatedHeight(width: 350)
            if height > Self.budget { break }
        }
        return out.reversed()
    }
}
#endif
