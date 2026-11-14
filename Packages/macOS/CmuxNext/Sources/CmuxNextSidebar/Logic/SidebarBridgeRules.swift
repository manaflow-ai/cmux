import Foundation

/// The App sidebar bridge's decision rules, asked of Rust (`cmux-layout-reducer::sidebar_bridge`, op
/// `sidebar_bridge`, with their tests). The bridge reads the facts and acts on the answer. Each rule runs
/// once per intent, click, editor row or machine header, never per frame, hover, drag move or status tick.
/// Daemons cross as their identity (`AnyObject`), workspaces as indexes; a nil answer means the library did not
/// answer, and the caller does the safe thing (a drop snaps back, a click does nothing).
public nonisolated struct SidebarBridgeRules: Sendable {
    public init() {}

    // MARK: Drops and pins (SidebarBridge+Intents)

    public enum ReorderPins: Equatable, Sendable {
        /// A drop on Pinned of workspaces that all are pinned: they snap back.
        case snapBack
        /// A drop on Pinned (or a custom section): these get the pin; nothing else moves.
        case pin([Int])
        /// A drop on a machine's section: these lose the pin, then the move goes on.
        case reorder(unpin: [Int])
    }

    /// The pin side of a reorder into `section` (a machine's is `daemon`'s) of workspaces `(pinned, daemon)`.
    public func reorderPins(into section: SectionID, daemon: AnyObject?, _ workspaces: [(pinned: Bool, daemon: AnyObject?)]) -> ReorderPins? {
        let kind: RuleJSON = switch section {
        case .pinned: ["kind": "pinned"]
        case .custom: ["kind": "custom"]
        case .machine: ["kind": "machine", "daemon": id(daemon)]
        }
        guard let reply = ask("reorder_pins", ["section": kind, "workspaces": .array(workspaces.map { ["pinned": .bool($0.pinned), "daemon": id($0.daemon)] })],
                              as: Tagged.self) else { return nil }
        switch reply.kind {
        case "snap_back": return .snapBack
        case "pin": return .pin(reply.workspaces ?? [])
        case "reorder": return .reorder(unpin: reply.unpin ?? [])
        default: return nil
        }
    }

    /// Which owners (by whether their daemon `supports` the pin) get the pin; `refused`: say it needs the
    /// capability; `snapBack`: nothing is sent.
    public func pinCommands(supports: [Bool]) -> (send: [Int], refused: Bool, snapBack: Bool)? {
        ask("pin_commands", ["supports": .array(supports.map(RuleJSON.bool))], as: PinReply.self).map { ($0.send, $0.refused, $0.snapBack) }
    }

    /// Whether one daemon owns every workspace (`owners`, one each).
    public func sameOwner(_ owners: [AnyObject]) -> Bool {
        guard case .int(let first)? = owners.first.map(id) else { return false }
        return (ask("same_daemon", ["owners": .array(owners.map(id))], as: Int?.self) ?? nil) == first
    }

    /// The items at a reply's `indexes`, in order (an index `items` does not have is skipped).
    public func pick<Item>(_ indexes: [Int]?, from items: [Item]) -> [Item] {
        (indexes ?? []).compactMap { $0 >= 0 ? items.dropFirst($0).first : nil }
    }

    public enum NewWorkspace: String, Sendable {
        /// The plain "+" in a local window: the person's New Workspace, as Cmd-N.
        case newTab
        /// A machine turned off by policy: nothing, never a local stand-in.
        case nothing
        /// On the machine the intent named, the window's machine, or the app's default.
        case onMachine, onWindow, onDefault
    }

    /// A sidebar New Workspace: `machine` says whether the intent names one and whether it has a daemon.
    public func newWorkspace(machine: Bool?, group: Bool, localWindow: Bool, windowDaemon: Bool) -> NewWorkspace? {
        let reply = ask("new_workspace", ["machine": RuleJSON(machine), "group": .bool(group), "local_window": .bool(localWindow),
                                          "window_daemon": .bool(windowDaemon)], as: Tagged.self)
        return switch (reply?.kind, reply?.on) {
        case ("new_tab", _): .newTab
        case ("create", "machine"): .onMachine
        case ("create", "window"): .onWindow
        case ("create", "default"): .onDefault
        case ("nothing", _): .nothing
        default: nil
        }
    }

    // MARK: Groups (SidebarGroupFlow, SidebarBridge+Personal)

    /// New Group never stacks a second group on a `whole` group a person asks for unnamed (`editWhole`); a
    /// person's unnamed new group opens its editor (`editNew`).
    public func newGroup(byUser: Bool, unnamed: Bool, personal: Bool, whole: Bool) -> (editWhole: Bool, editNew: Bool)? {
        ask("new_group", ["by_user": .bool(byUser), "unnamed": .bool(unnamed), "personal": .bool(personal), "whole": .bool(whole)],
            as: NewGroupReply.self).map { ($0.editWhole, $0.editNew) }
    }

    /// A new personal group's index: the sidebar's place wins, else the caller's (`Int.max`: last). The inner nil
    /// is the daemon's default (last); the outer nil, no answer.
    public func groupCreateIndex(placed: Int?, requested: Int?) -> Int?? {
        ask("group_create_index", ["placed": RuleJSON(placed), "requested": RuleJSON(requested)], as: Int?.self)
    }

    /// A group editor row: whether a group made empty stays when the editor closes, and whether it runs an action.
    public func editorItem(_ item: String) -> (keepsGroup: Bool, performs: Bool)? {
        ask("editor_item", ["item": .string(item)], as: EditorReply.self).map { ($0.keepsGroup, $0.performs) }
    }

    public enum GroupChange: Hashable, Sendable {
        case unchanged, clear
        case set(String)
    }

    public struct Placements: Sendable {
        /// The steps whose workspaces join (or leave for loose) the drop's group.
        public var moving: [Int]
        /// One `workspace.place` per step, in plan order.
        public var places: [(step: Int, group: GroupChange, index: Int)]
        /// The groups that move to the drop's first slot, after the places.
        public var regroups: [(group: String, topIndex: Int)]
    }

    /// A personal drop plan's commands: a moving step joins `group` (or goes loose), the rest keep theirs;
    /// `regroup` moves to `first` only on v2 personal state.
    public func placements(_ steps: [(moves: Bool, index: Int)], group: String?, statePersonal: Bool, regroup: [String], first: Int?) -> Placements? {
        let fields: [String: RuleJSON] = ["steps": .array(steps.map { ["moves": .bool($0.moves), "index": .int($0.index)] }), "group": RuleJSON(group),
                                          "state_personal": .bool(statePersonal), "regroup": .array(regroup.map(RuleJSON.string)), "first": RuleJSON(first)]
        guard let reply = ask("placement_commands", fields, as: PlacementReply.self) else { return nil }
        return Placements(moving: reply.moving, places: reply.places.map { place in
            let change: GroupChange = switch (place.group.kind, place.group.id) {
            case ("set", let id?): .set(id)
            case ("clear", _): .clear
            default: .unchanged
            }
            return (place.step, change, place.index)
        }, regroups: reply.regroups.map { ($0.group, $0.topIndex) })
    }

    // MARK: Machine headers (SidebarBridge, Remote/SidebarBridge+SSH)

    /// A header from its daemon's connection (`connecting`, `connected`, `disconnected`, `failed`) and
    /// capability level (`current`, `limited`, `incompatible`); `compatibilityDetail`: the detail names it.
    public func machineStatus(kind: SidebarMachine.Kind, connection: String, live: Bool, compatibility: String?,
                              startupUnavailable: Bool) -> (status: SidebarMachine.Status, compatibilityDetail: Bool)? {
        header("machine_status", ["kind": .string(kind.rawValue), "connection": .string(connection), "live": .bool(live),
                                  "compatibility": RuleJSON(compatibility), "startup_unavailable": .bool(startupUnavailable)])
    }

    /// An SSH header: its link's status, except a connected machine offered an update says Update Available.
    public func sshStatus(link: SidebarMachine.Status, updateOffered: Bool, compatibilityKnown: Bool) -> (status: SidebarMachine.Status, compatibilityDetail: Bool)? {
        header("ssh_status", ["link": .string(link.rawValue), "update_offered": .bool(updateOffered), "compatibility": .bool(compatibilityKnown)])
    }

    /// What a chat that needs a machine finds its link doing: `up`, `coming`, `down` (reconnect it) or `stuck`.
    /// Only a link that dropped reconnects on use; an SSH session waiting on its person, or no header, is stuck.
    @MainActor public func paneUse(waitsForUser: Bool, header: SidebarMachine.Status?) -> String {
        ask("pane_use", ["waits_for_user": .bool(waitsForUser), "link": RuleJSON(header?.linkState.rawValue),
                         "reconnects_on_use": .bool(header.map(MachineLinkState.reconnectsOnUse) ?? false)], as: String.self) ?? "stuck"
    }

    /// A Machines section row's link as one ``MachineLinkState`` (`machine.list`): connected first, then
    /// what its server says (`serverState`: `paused`, `resuming`, `failed`, `deleted`), then whether the
    /// link is being made. Nil when the library did not answer.
    public func rowLink(connected: Bool, connecting: Bool, serverState: String?) -> MachineLinkState? {
        ask("row_link", ["connected": .bool(connected), "connecting": .bool(connecting), "server_state": RuleJSON(serverState)],
            as: String.self).flatMap(MachineLinkState.init(rawValue:))
    }

    // MARK: Cards (SidebarBridge+Cards) and items (SidebarBridge+Sections)

    public enum NoticeRoute: Equatable, Sendable {
        case closeUpdate, updateAction, useRealFeed, announcementTry, none
        case tip(String)
    }

    /// Where a notice button's press goes; the flags say the action parses as an update close option or card
    /// action, or is an allow-listed Try It.
    public func noticeAction(card: String, action: String, closeOption: Bool, cardAction: Bool, tryIt: Bool) -> NoticeRoute {
        let reply = ask("notice_action", ["card": .string(card), "action": .string(action), "close_option": .bool(closeOption),
                                          "card_action": .bool(cardAction), "try_it": .bool(tryIt)], as: Tagged.self)
        return switch (reply?.kind, reply?.tip) {
        case ("close_update", _): .closeUpdate
        case ("update_action", _): .updateAction
        case ("use_real_feed", _): .useRealFeed
        case ("announcement_try", _): .announcementTry
        case ("tip", let tip?): .tip(tip)
        default: .none
        }
    }

    public enum DismissRoute: Equatable, Sendable {
        case update, none
        case announcement(String), tip(String)
    }

    /// What a notice's x does.
    public func dismissNotice(_ card: String) -> DismissRoute {
        let reply = ask("dismiss_notice", ["card": .string(card)], as: Tagged.self)
        return switch (reply?.kind, reply?.id) {
        case ("update", _): .update
        case ("announcement", let id?): .announcement(id)
        case ("tip", let id?): .tip(id)
        default: .none
        }
    }

    /// What an app item's click may run, best first; the caller runs the first it has, and the last always runs.
    public func appActivation(_ app: String) -> [(action: String, appArgument: Bool)] {
        (ask("app_activation", ["app": .string(app)], as: [AppReply].self) ?? []).map { ($0.action, $0.appArgument) }
    }

    // MARK: Machine links (MachineLinkState)

    /// Every machine status's dot and whether using the machine reconnects it, keyed by the status's word: the
    /// table Rust owns (`status_links`), read once per launch by ``MachineLinkState``; nil when the library did not answer.
    public func statusLinks() -> [String: MachineLinkState.Shown]? {
        ask("status_links", [:], as: [String: LinkReply].self)?.compactMapValues { reply in
            MachineLinkState(rawValue: reply.link).map { MachineLinkState.Shown(link: $0, reconnectsOnUse: reply.reconnectsOnUse) }
        }
    }

    // MARK: The call

    private func id(_ object: AnyObject?) -> RuleJSON {
        object.map { .int(Int(bitPattern: UInt(bitPattern: ObjectIdentifier($0)))) } ?? .null
    }

    private func header(_ rule: String, _ fields: [String: RuleJSON]) -> (status: SidebarMachine.Status, compatibilityDetail: Bool)? {
        guard let reply = ask(rule, fields, as: HeaderReply.self), let status = SidebarMachine.Status(rawValue: reply.status) else { return nil }
        return (status, reply.compatibilityDetail)
    }

    private func ask<Reply: Decodable>(_ rule: String, _ fields: [String: RuleJSON], as: Reply.Type) -> Reply? {
        var fields = fields
        fields["rule"] = .string(rule)
        return RustSidebarClient.call("sidebar_bridge", RuleJSON.object(fields), as: Reply.self)
    }
}

/// A JSON value for a rule's request; nil optionals encode as null.
nonisolated enum RuleJSON: Encodable, ExpressibleByDictionaryLiteral, ExpressibleByStringLiteral {
    case null, bool(Bool), int(Int), string(String), array([RuleJSON]), object([String: RuleJSON])

    init(_ value: Bool?) { self = value.map(RuleJSON.bool) ?? .null }
    init(_ value: Int?) { self = value.map(RuleJSON.int) ?? .null }
    init(_ value: String?) { self = value.map(RuleJSON.string) ?? .null }
    init(dictionaryLiteral elements: (String, RuleJSON)...) { self = .object(Dictionary(elements, uniquingKeysWith: { _, last in last })) }
    init(stringLiteral value: String) { self = .string(value) }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .int(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }
}

private nonisolated struct Tagged: Decodable {
    let kind: String
    var workspaces: [Int]?, unpin: [Int]?, on: String?, tip: String?, id: String?
}

private nonisolated struct PinReply: Decodable {
    let send: [Int], refused: Bool, snapBack: Bool

    enum CodingKeys: String, CodingKey { case send, refused, snapBack = "snap_back" }
}

private nonisolated struct NewGroupReply: Decodable {
    let editWhole: Bool, editNew: Bool

    enum CodingKeys: String, CodingKey { case editWhole = "edit_whole", editNew = "edit_new" }
}

private nonisolated struct EditorReply: Decodable {
    let keepsGroup: Bool, performs: Bool

    enum CodingKeys: String, CodingKey { case keepsGroup = "keeps_group", performs }
}

private nonisolated struct PlacementReply: Decodable {
    struct Group: Decodable { let kind: String; var id: String? }
    struct Place: Decodable { let step: Int, group: Group, index: Int }
    struct Regroup: Decodable {
        let group: String, topIndex: Int

        enum CodingKeys: String, CodingKey { case group, topIndex = "top_index" }
    }

    let moving: [Int], places: [Place], regroups: [Regroup]
}

private nonisolated struct HeaderReply: Decodable {
    let status: String, compatibilityDetail: Bool

    enum CodingKeys: String, CodingKey { case status, compatibilityDetail = "compatibility_detail" }
}

private nonisolated struct AppReply: Decodable {
    let action: String, appArgument: Bool

    enum CodingKeys: String, CodingKey { case action, appArgument = "app_argument" }
}

private nonisolated struct LinkReply: Decodable {
    let link: String, reconnectsOnUse: Bool

    enum CodingKeys: String, CodingKey { case link, reconnectsOnUse = "reconnects_on_use" }
}
