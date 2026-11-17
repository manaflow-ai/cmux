public import CmuxHomeCore
import CmuxNextCompat
public import CmuxNextDesign
public import CmuxNextHomeModel
public import CmuxNextPages
public import CmuxNextSettings
public import Foundation

/// What the Messages page's list reads from the app beyond the conversations (the native
/// `HomeSidebarView` drew these from its `HomeSidebarModel`): moved here so the App only hands the sources.
@MainActor
public struct HomeMessagesListSources {
    /// The list's model (``HomeSidebarModel``, unfiltered): the rows' tags, the Cloud note, the teammates.
    public var model: () -> HomeSidebarModel?
    /// Everyone New Message offers (``HomeSidebarModel/withoutDM(_:rows:)`` keeps the ones with no DM yet).
    public var contacts: () -> [HomeContact]
    /// The inbox rows (whose DMs the search's people leave out).
    public var rows: () -> [InboxRow]
    /// The listed Chiefs changed: read their engines and pictures again (the rows' badges and avatars).
    public var chiefsChanged: () -> Void
    /// A conversation came or went (a lease arrived, a request was accepted): Message Requests may have changed.
    public var listedChanged: () -> Void

    public init(model: @escaping () -> HomeSidebarModel?, contacts: @escaping () -> [HomeContact], rows: @escaping () -> [InboxRow],
                chiefsChanged: @escaping () -> Void, listedChanged: @escaping () -> Void) {
        (self.model, self.contacts, self.rows, self.chiefsChanged, self.listedChanged) = (model, contacts, rows, chiefsChanged, listedChanged)
    }
}

/// The Messages list's app facts (`cmux.home.messages.list`, webviews/src/pages/home-messages/listFeed.ts):
/// - stream `list`: `{badges: {conversation: tag}, note: string | null, teammates: [{id, name}],
///   people: [{id, name}], header: {side, chipHeight, chipGap, chipPadding, textStep}}`: each
///   conversation's tag after its name ("Main · Cloud", "This Mac", an engine: `listBadge ??
///   backendBadge`), the quiet Cloud line under the list, the team members with no DM yet (rows
///   after the conversations while no search runs), everyone with no DM yet (the search's Teammates
///   section), and the header's sizes at `sidebar.density` and `sidebar.textSize`. Sent on subscribe and
///   once per change; the observation runs only while the page listens.
/// - `width.load {}` -> `{width: number | null}`, `width.save {width: number | null}`: the list's
///   width kept per window key (``HomeSidebarWidth``, the native list's keys, so a width set before stays).
///   Only the person's drag saves; null is the divider's double-click (back to the standard width).
@MainActor
public final class HomeMessagesListFeed: PageProvider {
    public nonisolated static let stream = HomeMessagesPageRoute.prefix + "list"
    public nonisolated static let widthPrefix = HomeMessagesPageRoute.prefix + "width."
    public nonisolated static let dragBandOp = HomeMessagesPageRoute.prefix + "dragBand"
    /// Every op and stream prefix this provider answers (the page's routes).
    public nonisolated static let prefixes = [stream, widthPrefix, dragBandOp]
    public var sources: HomeMessagesListSources?
    /// The page reported its list header's band and the controls in it (``HomeWindowDragStrip/setBand(_:controls:)``).
    public var onDragBand: @MainActor (CGRect, [CGRect]) -> Void = { _, _ in }
    private let widths: HomeSidebarWidth
    /// The window key the width is kept under (`home-dock`, `home-tab`, classic Home's window id).
    private let widthKey: @MainActor () -> String
    private var listeners: [UUID: @MainActor (JSONValue) -> Void] = [:]
    private var watch: Task<Void, Never>?
    private var chiefs: Set<String>?
    private var listed: Set<ConversationID>?

    public init(widths: HomeSidebarWidth = HomeSidebarWidth(), widthKey: @escaping @MainActor () -> String) {
        self.widths = widths
        self.widthKey = widthKey
    }

    nonisolated deinit {
        watch?.cancel()
    }

    public func call(_ op: String, params: JSONValue, context: PageCallContext) async throws -> JSONValue {
        let fields = params.objectValue ?? [:]
        switch op {
        case Self.widthPrefix + "load":
            return .object(["width": widths.width(window: widthKey()).map { .number(Double($0)) } ?? .null])
        case Self.widthPrefix + "save":
            guard let width = fields["width"]?.doubleValue else {
                widths.reset(window: widthKey())
                return .null
            }
            guard width.isFinite, width >= Double(HomeSidebarWidth.minimum), width <= 10_000 else { throw PageError.invalidParams("width must be a list width") }
            widths.save(CGFloat(width), window: widthKey())
            return .null
        case Self.dragBandOp:
            guard let band = Self.rect(fields["band"]) else { throw PageError.invalidParams("band must be a rect") }
            onDragBand(band, (fields["controls"]?.arrayValue ?? []).prefix(16).compactMap(Self.rect))
            return .null
        default:
            throw PageError.unknownOp(op)
        }
    }

    public func subscribe(_ stream: String, filter: JSONValue, context: PageCallContext,
                          onEvent: @escaping @MainActor (JSONValue) -> Void) async throws -> PageSubscription {
        guard stream == Self.stream else { throw PageError.unknownOp(stream) }
        let key = UUID()
        listeners[key] = onEvent
        onEvent(value())
        if watch == nil { follow() }
        return PageSubscription { [weak self] in
            guard let self else { return }
            listeners[key] = nil
            if listeners.isEmpty { watch?.cancel(); watch = nil }
        }
    }

    /// Follows what the value reads (Observation) while a page listens; sends only a change, and tells
    /// the sources when the listed Chiefs or conversations changed (outside the tracked read).
    private func follow() {
        // task-owner: lives while the page listens to `list` (cancelled with its last listener); event-driven (Observation)
        watch = Task { [weak self] in
            var last: JSONValue?
            for await read in ObservationStream({ [weak self] in self?.read() ?? Read(value: .null, chiefs: [], listed: []) }) {
                guard let self else { return }
                noteChanges(read)
                guard read.value != last else { continue }
                last = read.value
                for listener in listeners.values { listener(read.value) }
            }
        }
    }

    /// One read of the stream's value with the listed Chiefs and conversations it came from.
    struct Read: Equatable, Sendable {
        var value: JSONValue
        var chiefs: Set<String>
        var listed: Set<ConversationID>
    }

    func value() -> JSONValue { read().value }

    private func read() -> Read {
        let model = sources?.model()
        let items = (model?.pinned ?? []) + (model?.rows ?? [])
        let people = sources.map { HomeSidebarModel.withoutDM($0.contacts(), rows: $0.rows()) } ?? []
        return Read(value: Self.json(model: model, people: people, header: HomeMessagesHeaderMetrics(tokens: SidebarRowTokens.current)),
                    chiefs: Set(items.filter(\.isChief).flatMap { $0.people.map(\.id) }), listed: Set(items.map(\.id)))
    }

    private func noteChanges(_ read: Read) {
        guard sources != nil else { return }
        if read.chiefs != chiefs {
            chiefs = read.chiefs
            sources?.chiefsChanged()
        }
        if read.listed != listed {
            let first = listed == nil
            listed = read.listed
            if !first { sources?.listedChanged() }
        }
    }

    /// `{x, y, width, height}` in page points, finite and not negative in size; nil otherwise.
    static func rect(_ value: JSONValue?) -> CGRect? {
        guard let fields = value?.objectValue, let x = fields["x"]?.doubleValue, let y = fields["y"]?.doubleValue,
              let width = fields["width"]?.doubleValue, let height = fields["height"]?.doubleValue,
              [x, y, width, height].allSatisfy(\.isFinite), width >= 0, height >= 0, width < 100_000, height < 100_000 else { return nil }
        return CGRect(x: x, y: y, width: width, height: height)
    }

    public static func json(model: HomeSidebarModel?, people: [HomeContact], header: HomeMessagesHeaderMetrics) -> JSONValue {
        var badges: [String: JSONValue] = [:]
        for item in (model?.pinned ?? []) + (model?.rows ?? []) {
            if let tag = item.listBadge ?? item.backendBadge { badges[item.id.rawValue] = .string(tag) }
        }
        let person = { (contact: HomeContact) in JSONValue.object(["id": .string(contact.id.rawValue), "name": .string(contact.name)]) }
        return .object([
            "badges": .object(badges),
            "note": model?.note.map(JSONValue.string) ?? .null,
            "teammates": .array((model?.teammates ?? []).map(person)),
            "people": .array(people.map(person)),
            "header": header.json,
        ])
    }
}

/// The list header's sizes under `sidebar.density` and `sidebar.textSize` (the native
/// `HomeSidebarHeaderMetrics`, the user 2026-11-04: the Sidebar States Playground's Home filter
/// columns all looked the same). Compact with the default text is ``standard`` (a 30 pt filter
/// circle and search field, a 24 pt Unread chip); a bigger density or text size adds the band
/// tokens' extra height (``SidebarRowTokens/band``: Expanded is Comfortable's) to the circle and the
/// chip, and the text step to their text. Pure.
public nonisolated struct HomeMessagesHeaderMetrics: Equatable, Sendable {
    public var side: CGFloat
    public var chipHeight: CGFloat
    public var chipGap: CGFloat
    public var chipPadding: CGFloat
    /// Points added to the chip's text and xmark and to the empty list's text.
    public var textStep: CGFloat

    public static let standard = HomeMessagesHeaderMetrics(side: 30, chipHeight: 24, chipGap: 6, chipPadding: 10, textStep: 0)

    public init(side: CGFloat, chipHeight: CGFloat, chipGap: CGFloat, chipPadding: CGFloat, textStep: CGFloat) {
        (self.side, self.chipHeight, self.chipGap, self.chipPadding, self.textStep) = (side, chipHeight, chipGap, chipPadding, textStep)
    }

    public init(tokens: SidebarRowTokens) {
        let band = tokens.band
        let extra = band.extraHeight
        let base = Self.standard
        self.init(side: base.side + extra, chipHeight: base.chipHeight + extra, chipGap: base.chipGap + (extra / 2).rounded(),
                  chipPadding: base.chipPadding + (extra / 2).rounded(), textStep: band.textSize.textStep)
    }

    var json: JSONValue {
        .object(["side": .number(side), "chipHeight": .number(chipHeight), "chipGap": .number(chipGap),
                 "chipPadding": .number(chipPadding), "textStep": .number(textStep)])
    }
}

extension HomeSidebarModel {
    /// `contacts` with no DM in `rows` yet: who a search's Teammates section may list (the native
    /// list's search section, ``people`` before the name filter, which the page applies as it types).
    public static func withoutDM(_ contacts: [HomeContact], rows: [InboxRow]) -> [HomeContact] {
        let peers = Set(rows.filter { $0.kind == .direct }.flatMap { $0.summary.participants.map(\.id) })
        return contacts.filter { !peers.contains($0.id) }
    }
}
