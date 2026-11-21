import AppKit
import CmuxAgentBrands
import CmuxNextDesign
public import CmuxNextPages
import CmuxNextSettings
import Foundation

public extension PageDescriptor {
    /// The sidebar's chat history blocks: cmux-page://cmux.sidebar-chats/, built by
    /// scripts/cmux-next/build-pages-web.sh from webviews/src/pages/sidebar-chats. One page per block the list
    /// shows (Pinned, Earlier; ``SidebarChatHistoryHost``). The page owns no data: the host streams the block,
    /// and every click comes back as a call the host checks. It takes the first click, as the native rows did.
    static let sidebarChats = PageDescriptor(id: "cmux.sidebar-chats", resource: "sidebar-chats",
                                             namespaces: [SidebarChatHistoryProvider.prefix], commands: [],
                                             acceptsFirstMouse: true)
}

/// What one chat history block's page draws (`cmux.sidebarChats.block`, webviews/src/pages/sidebar-chats/model.ts):
/// the session tree's Pinned or Earlier chats of `SidebarChatHistoryState`, with the sidebar's grid in points. The
/// list's layout keeps the block's height (`SidebarChatHistoryState.pinnedHeight` / `earlierHeight`); the page draws
/// into it and reports the same height.
struct SidebarChatHistoryBlock: Equatable {
    struct Row: Equatable {
        var id: String
        var title: String
        /// The chat's age ("12m", `SidebarChatsDesign.age`).
        var meta: String?
        var harness: String?
        /// A harness no brand mark knows: its generic mark's stable color (`GroupColor.unset(id:)`), as CSS.
        var markColor: String?
    }

    enum Tail: String { case more, loading }

    var part: SidebarChatHistoryHost.Part
    var folded: Bool
    var rows: [Row]
    var tail: Tail?
    /// The sidebar's grid in points (webviews `SidebarChatsMetrics`).
    var metrics: [String: Double]

    /// The `part` block of `state` at `metrics`, for a block `width` points wide; `now` dates the ages. Built in
    /// the sidebar's theme (an unknown harness's mark color).
    @MainActor
    init(part: SidebarChatHistoryHost.Part, state: SidebarChatHistoryState, metrics m: SidebarLayoutMetrics, width: CGFloat, now: Date) {
        self.part = part
        let earlier = part == .earlier
        folded = earlier && state.earlierFolded
        let chats = folded ? [] : (earlier ? state.earlier : state.pinned)
        rows = chats.map { chat in
            Row(id: chat.id, title: chat.title, meta: SidebarChatsDesign.age(from: chat.updatedAt, to: now), harness: chat.harness,
                markColor: chat.harness.flatMap { AgentBrandCatalog.brand(for: $0) == nil ? Self.css(GroupColor.unset(id: $0).markColor) : nil })
        }
        tail = !earlier || folded ? nil : state.showsLoading ? .loading : state.hasMore ? .more : nil
        metrics = Self.metrics(m, width: width)
    }

    /// The sidebar's columns and sizes for the page, from the same `SidebarStyle` the workspace rows lay out with.
    @MainActor
    static func metrics(_ m: SidebarLayoutMetrics, width: CGFloat) -> [String: Double] {
        let width = width > 0 ? width : 240
        let leading = SidebarStyle.titleLeading
        let chevron = SidebarStyle.trailingColumnFrame(rowWidth: width, centerY: 0, side: Metrics.smallIconSize)
        let values: [String: CGFloat] = [
            "header": m.sectionHeaderHeight, "row": m.rowHeight, "spacing": m.rowSpacing,
            "radius": SidebarStyle.rowCornerRadius,
            "iconX": leading, "iconBox": SidebarStyle.iconColumnBox, "glyph": SidebarStyle.kindGlyphSize,
            "textX": SidebarStyle.titleTextX(leading: leading, iconSide: SidebarStyle.iconColumnBox),
            "plainTextX": SidebarStyle.titleTextX(leading: leading, iconSide: 0),
            "headerX": SidebarStyle.columns(rowWidth: width).lead,
            "edge": Metrics.space2,
            "headerEnd": width - SidebarStyle.trailingColumnStart(rowWidth: width) + Metrics.space2,
            "chevronEnd": width - chevron.maxX, "chevron": Metrics.smallIconSize,
            "titleSize": SidebarStyle.titleFont.pointSize, "metaSize": SidebarStyle.subtitleFont.pointSize,
            "headerSize": SidebarStyle.headerFont.pointSize,
        ]
        return values.mapValues { Double($0) }
    }

    /// Whether `chat` is a row of this block (a page's call may name only those).
    func lists(_ chat: String) -> Bool { rows.contains { $0.id == chat } }

    /// The block's height in points, as the page lays it out (`blockHeight` in model.ts).
    var height: Double {
        let m = { (key: String) in metrics[key] ?? 0 }
        if folded { return m("header") }
        return m("header") + Double(rows.count + (tail == nil ? 0 : 1)) * (m("row") + m("spacing"))
    }

    func event(revision: Int) -> JSONValue {
        .object([
            "revision": .number(Double(revision)),
            "part": .string(part.rawValue),
            "folded": .bool(folded),
            "rows": .array(rows.map { row in
                .object([
                    "id": .string(row.id), "title": .string(row.title),
                    "meta": row.meta.map(JSONValue.string) ?? .null,
                    "harness": row.harness.map(JSONValue.string) ?? .null,
                    "markColor": row.markColor.map(JSONValue.string) ?? .null,
                ])
            }),
            "tail": tail.map { .string($0.rawValue) } ?? .null,
            "metrics": .object(metrics.mapValues(JSONValue.number)),
        ])
    }

    /// `color` as CSS `rgba(...)` in sRGB.
    static func css(_ color: NSColor) -> String? {
        guard let rgb = color.usingColorSpace(.sRGB) else { return nil }
        let channel = { (value: CGFloat) in Int((min(max(value, 0), 1) * 255).rounded()) }
        return "rgba(\(channel(rgb.redComponent)), \(channel(rgb.greenComponent)), \(channel(rgb.blueComponent)), \(min(max(rgb.alphaComponent, 0), 1)))"
    }
}

/// Serves `cmux.sidebarChats.*` to one chat history block's page (webviews/src/pages/sidebar-chats/model.ts):
///
/// - stream `block`: the block to draw, a new `revision` on every change; a (re)subscribing page gets the latest.
/// - `open {revision, chat}`, `fold {revision}`, `more {revision}`, `menu {revision, chat, point}`: the person's click
///   on a row, Earlier's header, Show More, or a row's right click. Each needs the person's own click in the page view
///   (``PageCallContext/userGesture``) and spends it: page script alone acts on nothing. A VoiceOver press counts as
///   that click while VoiceOver runs (`PageAccessibilityPress`), as the native rows' `accessibilityPerformPress()` did.
///   `chat` must be a row the host sent, so a page can open or pin only the chats it was shown.
/// - `ready {revision, height}`: the page drew `revision` at `height` CSS px (the host shows the page then).
@MainActor
final class SidebarChatHistoryProvider: PageProvider {
    static let prefix = "cmux.sidebarChats."
    static let blockStream = prefix + "block"

    enum Call: Equatable {
        case open(String)
        case fold
        case more
        case menu(String, CGPoint)
        case ready(revision: Int, height: Double)
    }

    private(set) var block: SidebarChatHistoryBlock?
    private(set) var revision = 0
    /// Runs each accepted call (the host: open, fold, Show More, the menu until it closes, the ready report).
    var onCall: (@MainActor (Call) async -> Void)?
    private var listener: (@MainActor (JSONValue) -> Void)?
    /// The gesture the last call spent (one action per click).
    private var spentGesture: TimeInterval?

    /// Sends `block` when it differs from the last one sent; returns whether it did.
    @discardableResult
    func push(_ block: SidebarChatHistoryBlock) -> Bool {
        guard block != self.block else { return false }
        self.block = block
        revision += 1
        listener?(block.event(revision: revision))
        return true
    }

    /// The call `op` names, or nil when `op` or its params are not the page's.
    static func decode(_ op: String, _ params: JSONValue) -> Call? {
        switch op {
        case prefix + "open": return params["chat"]?.stringValue.map(Call.open)
        case prefix + "fold": return .fold
        case prefix + "more": return .more
        case prefix + "menu":
            guard let chat = params["chat"]?.stringValue, let point = params["point"] else { return nil }
            return .menu(chat, CGPoint(x: point["x"]?.doubleValue ?? 0, y: point["y"]?.doubleValue ?? 0))
        case prefix + "ready":
            guard let revision = params["revision"]?.intValue, let height = params["height"]?.doubleValue, height >= 0 else { return nil }
            return .ready(revision: revision, height: height)
        default: return nil
        }
    }

    func call(_ op: String, params: JSONValue, context: PageCallContext) async throws -> JSONValue {
        guard let call = Self.decode(op, params) else { throw PageError.invalidParams(op) }
        if case .ready = call {
            await onCall?(call)
            return .null
        }
        guard context.userGesture, let event = context.gestureEvent, event != spentGesture else {
            throw PageError(code: PageNativeOp.userOnlyCode, message: "A chat history row acts only on the person's click.")
        }
        switch call {
        case let .open(chat), let .menu(chat, _):
            guard block?.lists(chat) == true else { throw PageError.invalidParams(op) }
        case .fold, .more:
            guard block?.part == .earlier else { throw PageError.invalidParams(op) }
        case .ready:
            break
        }
        spentGesture = event
        await onCall?(call)
        return .null
    }

    func subscribe(_ stream: String, filter: JSONValue, context: PageCallContext,
                   onEvent: @escaping @MainActor (JSONValue) -> Void) async throws -> PageSubscription {
        guard stream == Self.blockStream else { throw PageError.unknownOp(stream) }
        listener = onEvent
        // A page subscribes once per load (a reload after a crash too): the latest block, if any.
        if let block { onEvent(block.event(revision: revision)) }
        return PageSubscription { [weak self] in self?.listener = nil }
    }

}
