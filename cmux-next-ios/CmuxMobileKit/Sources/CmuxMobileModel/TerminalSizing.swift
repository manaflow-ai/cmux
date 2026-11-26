import Foundation
import Observation

// Terminal sizing policy on the phone (cmux-next-ios/PROTOCOL.md "Terminal
// sizing policy (host-size-policy-v1)"): the Mac's daemon publishes one
// shared terminal's size state (docs/shared-terminal-sizing.md "Size state")
// and keeps one sizing policy per Mac; the phone shows both and sends its
// preference. Pure values and the presentation the Settings page and the
// Connected Devices sheet draw.

/// A terminal grid in cells.
public struct TerminalGrid: Hashable, Sendable {
    public var cols: Int
    public var rows: Int

    public init(cols: Int, rows: Int) {
        self.cols = cols
        self.rows = rows
    }

    /// `120×40`.
    public var label: String { "\(cols)×\(rows)" }

    static func decode(_ value: Any?) -> TerminalGrid? {
        guard let object = value as? [String: Any], let cols = object["cols"] as? Int, let rows = object["rows"] as? Int,
              cols > 0, rows > 0 else { return nil }
        return TerminalGrid(cols: cols, rows: rows)
    }
}

/// One attached view of a terminal, as the Mac's daemon publishes it.
public struct TerminalSizeParticipant: Identifiable, Hashable, Sendable {
    public var id: String
    public var deviceKind: String
    public var deviceName: String?
    public var displayName: String?
    public var deviceID: String?
    /// The size this viewer asks for; nil while it does not claim one (its
    /// terminal is not on screen).
    public var viewport: TerminalGrid?
    /// Whether it counts toward the grid now.
    public var counts: Bool

    public init(id: String, deviceKind: String, deviceName: String? = nil, displayName: String? = nil,
                deviceID: String? = nil, viewport: TerminalGrid? = nil, counts: Bool = true) {
        self.id = id
        self.deviceKind = deviceKind
        self.deviceName = deviceName
        self.displayName = displayName
        self.deviceID = deviceID
        self.viewport = viewport
        self.counts = counts
    }

    /// A Mac, a cmux-tui frontend, or the desktop app on Linux or Windows.
    public var isDesktop: Bool { ["mac", "tui", "linux", "windows"].contains(deviceKind) }

    static func decode(_ value: Any) -> TerminalSizeParticipant? {
        guard let object = value as? [String: Any], let id = object["id"] as? String else { return nil }
        return TerminalSizeParticipant(
            id: id,
            deviceKind: object["device_kind"] as? String ?? "unknown",
            deviceName: (object["device_name"] as? String).flatMap { $0.isEmpty ? nil : $0 },
            displayName: (object["display_name"] as? String).flatMap { $0.isEmpty ? nil : $0 },
            deviceID: (object["device_id"] as? String).flatMap { $0.isEmpty ? nil : $0 },
            viewport: TerminalGrid.decode(object["viewport"]),
            counts: object["counts"] as? Bool ?? false
        )
    }
}

/// A shared terminal's size state (`size-state`, `get-size-state`).
public struct TerminalSizeState: Hashable, Sendable {
    public var generation: Int
    public var grid: TerminalGrid
    /// `latest`, `smallest`, `largest`, `priority`, `fixed`, `held`, `priority-fallback`.
    public var reason: String
    /// The participants that set a dimension.
    public var owners: [String]
    /// The engine policy's mode on this terminal.
    public var mode: String
    public var participants: [TerminalSizeParticipant]

    public init(generation: Int, grid: TerminalGrid, reason: String, owners: [String], mode: String,
                participants: [TerminalSizeParticipant]) {
        self.generation = generation
        self.grid = grid
        self.reason = reason
        self.owners = owners
        self.mode = mode
        self.participants = participants
    }

    /// Decodes the wire object (docs/shared-terminal-sizing.md "Size state").
    public static func decode(_ value: Any?) -> TerminalSizeState? {
        guard let object = value as? [String: Any], let grid = TerminalGrid.decode(object) else { return nil }
        let policy = object["policy"] as? [String: Any]
        return TerminalSizeState(
            generation: object["generation"] as? Int ?? 0,
            grid: grid,
            reason: object["reason"] as? String ?? "held",
            owners: object["owners"] as? [String] ?? [],
            mode: policy?["mode"] as? String ?? "latest",
            participants: (object["participants"] as? [Any] ?? []).compactMap(TerminalSizeParticipant.decode)
        )
    }
}

/// The Mac's sizing policy (`mobile.terminalSizing` on the Mac).
public enum HostSizeMode: String, CaseIterable, Identifiable, Sendable {
    case smallest, mac, latest, priority

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .smallest: "Fit the Smallest Viewer"
        case .mac: "Prefer This Mac"
        case .latest: "Prefer the Active Device"
        case .priority: "Priority Order"
        }
    }

    /// One line under the picker, as in the classic app's size sheet.
    public var explanation: String {
        switch self {
        case .smallest: "Every device showing the terminal sees all of it. A phone makes the Mac's pane smaller while it shows the terminal."
        case .mac: "The Mac keeps its size. Phones scroll sideways or leave space below the terminal."
        case .latest: "The device you typed on or tapped last sets the size."
        case .priority: "The first device in this list that shows the terminal sets the size. Drag to reorder."
        }
    }

    /// Unknown values read as the default, as on the Mac.
    public init(wire: String?) {
        self = wire.flatMap(HostSizeMode.init(rawValue:)) ?? .smallest
    }
}

/// The Mac's policy: its mode and its priority order.
public struct HostSizePolicy: Hashable, Sendable {
    public var mode: HostSizeMode
    public var order: [String]

    public init(mode: HostSizeMode = .smallest, order: [String] = []) {
        self.mode = mode
        self.order = order
    }

    // Device tokens of the priority order (`mobile.terminalSizingOrder`).

    /// This Mac's own views.
    public static let macToken = "mac"

    /// The viewer whose device id is `id`.
    public static func deviceToken(_ id: String) -> String { "device:\(id)" }

    /// Most tokens the Mac keeps in an order.
    public static let maxOrder = 32

    /// A token the Mac accepts: `mac`, or `device:<id>` with a 1 to 128
    /// character id of `[A-Za-z0-9_.:-]` (the daemon refuses a whole order
    /// with any other token).
    public static func isValidToken(_ token: String) -> Bool {
        if token == macToken { return true }
        guard let id = deviceID(fromToken: token), id.utf8.count <= 128 else { return false }
        return id.utf8.allSatisfy { byte in
            (byte >= 0x30 && byte <= 0x39) || (byte >= 0x41 && byte <= 0x5A) || (byte >= 0x61 && byte <= 0x7A)
                || byte == UInt8(ascii: "_") || byte == UInt8(ascii: ".") || byte == UInt8(ascii: ":") || byte == UInt8(ascii: "-")
        }
    }

    /// The device id of a `device:<id>` token.
    public static func deviceID(fromToken token: String) -> String? {
        guard token.hasPrefix("device:") else { return nil }
        let id = String(token.dropFirst("device:".count))
        return id.isEmpty ? nil : id
    }

    public static func decode(_ value: Any?) -> HostSizePolicy? {
        guard let object = value as? [String: Any] else { return nil }
        return HostSizePolicy(mode: HostSizeMode(wire: object["mode"] as? String), order: object["order"] as? [String] ?? [])
    }

    /// The `policy` param of `set-host-size-policy`.
    public var wire: [String: Any] { ["mode": mode.rawValue, "order": order] }
}

/// `get-host-size-policy`'s answer.
public struct HostSizePolicyInfo: Hashable, Sendable {
    public var policy: HostSizePolicy
    /// The participant ids of the asked terminal that are the Mac's own views.
    public var macParticipants: Set<String>

    public init(policy: HostSizePolicy, macParticipants: Set<String> = []) {
        self.policy = policy
        self.macParticipants = macParticipants
    }

    /// Decodes a reply's `data`.
    public static func decode(_ value: Any?) -> HostSizePolicyInfo? {
        guard let object = value as? [String: Any], let policy = HostSizePolicy.decode(object["policy"]) else { return nil }
        return HostSizePolicyInfo(policy: policy, macParticipants: Set(object["mac_participants"] as? [String] ?? []))
    }
}

/// Reads and changes a Mac's sizing policy over its link.
@MainActor
public protocol TerminalSizingService: AnyObject {
    /// This phone's device id on its links: its token is `device:<id>`.
    var thisDeviceID: String? { get }
    func hostPolicy(macID: String, surface: Int?) async throws -> HostSizePolicyInfo
    func setHostPolicy(macID: String, policy: HostSizePolicy) async throws -> HostSizePolicy
}

/// One terminal's live size state on this phone, fed by its attach stream.
@MainActor
@Observable
public final class TerminalSizingLive {
    public private(set) var state: TerminalSizeState?
    /// This phone's own participant id on the terminal.
    public private(set) var selfParticipant: String?

    public init() {}

    /// A newer state (by generation; a state from a new attach replaces any).
    public func apply(_ state: TerminalSizeState?, selfParticipant: String?, reset: Bool = false) {
        if let selfParticipant { self.selfParticipant = selfParticipant }
        guard let state else { return }
        if !reset, let current = self.state, state.generation <= current.generation { return }
        self.state = state
    }

    /// The view left (the attach ended): no live state until the next attach.
    public func clear() {
        state = nil
        selfParticipant = nil
    }

    /// Whether this phone sets a dimension of the grid now.
    public var selfIsOwner: Bool {
        guard let selfParticipant, let state else { return false }
        return state.owners.contains(selfParticipant)
    }
}

/// What the Connected Devices sheet and the Settings page draw.
public struct TerminalSizingPresentation: Equatable, Sendable {
    public struct Row: Identifiable, Equatable, Sendable {
        public var id: String
        public var title: String
        /// `120×40`, or "Not showing it" without a claimed size.
        public var detail: String
        public var setsSize: Bool
        public var symbol: String
    }

    public struct OrderRow: Identifiable, Equatable, Sendable {
        public var id: String { token }
        public var token: String
        public var title: String
        public var symbol: String
    }

    public var state: TerminalSizeState?
    public var selfParticipant: String?
    public var macParticipants: Set<String>
    public var thisDeviceID: String?

    public init(state: TerminalSizeState?, selfParticipant: String?, macParticipants: Set<String>, thisDeviceID: String?) {
        self.state = state
        self.selfParticipant = selfParticipant
        self.macParticipants = macParticipants
        self.thisDeviceID = thisDeviceID
    }

    private func isThisMac(_ participant: TerminalSizeParticipant) -> Bool {
        macParticipants.contains(participant.id)
    }

    private func isThisPhone(_ participant: TerminalSizeParticipant) -> Bool {
        participant.id == selfParticipant || (thisDeviceID != nil && participant.deviceID == thisDeviceID && !participant.isDesktop)
    }

    public func title(of participant: TerminalSizeParticipant) -> String {
        if isThisMac(participant) { return "This Mac" }
        if isThisPhone(participant) { return "This iPhone" }
        if let name = participant.deviceName ?? participant.displayName { return name }
        switch participant.deviceKind {
        case "mac": return "Another Mac"
        case "iphone": return "An iPhone"
        case "ipad": return "An iPad"
        case "tui": return "A terminal"
        default: return "Another device"
        }
    }

    private static func symbol(kind: String) -> String {
        switch kind {
        case "mac", "linux", "windows": "laptopcomputer"
        case "iphone": "iphone"
        case "ipad": "ipad"
        case "tui": "apple.terminal"
        default: "display"
        }
    }

    /// One row per connected viewer, in attach order.
    public var rows: [Row] {
        guard let state else { return [] }
        return state.participants.map { participant in
            Row(id: participant.id, title: title(of: participant),
                detail: participant.viewport?.label ?? "Not showing it",
                setsSize: state.owners.contains(participant.id),
                symbol: Self.symbol(kind: participant.deviceKind))
        }
    }

    /// `120 × 40`.
    public var gridTitle: String? {
        state.map { "\($0.grid.cols) × \($0.grid.rows)" }
    }

    /// Why the grid has its size.
    public var reasonText: String? {
        guard let state else { return nil }
        let owners = state.participants.filter { state.owners.contains($0.id) }.map(title(of:))
        let named = owners.isEmpty ? nil : ListFormatter.localizedString(byJoining: owners)
        switch state.reason {
        case "smallest": return "Fits the smallest viewer" + (named.map { ": \($0)" } ?? "")
        case "largest": return "Fits the largest viewer" + (named.map { ": \($0)" } ?? "")
        case "fixed": return "Fixed size"
        case "held": return "Kept from the last viewer"
        case "priority-fallback": return named.map { "Set by \($0), active last" } ?? "Set by the device active last"
        case "priority": return named.map { "Set by \($0), first in order" } ?? "Set by the first device in order"
        default: return named.map { "Set by \($0)" } ?? "Set by the device active last"
        }
    }

    /// The token of a viewer in the priority order.
    public func token(of participant: TerminalSizeParticipant) -> String? {
        if isThisMac(participant) { return HostSizePolicy.macToken }
        return participant.deviceID.map(HostSizePolicy.deviceToken)
    }

    /// The priority list to show: the stored order first, then every viewer
    /// not in it (this Mac and this iPhone first), so a reorder ranks every
    /// device in sight. Stored tokens of absent devices keep their slots.
    public func orderRows(_ order: [String]) -> [OrderRow] {
        var tokens: [String] = []
        func add(_ token: String?) {
            guard let token, tokens.count < HostSizePolicy.maxOrder, HostSizePolicy.isValidToken(token),
                  !tokens.contains(token) else { return }
            tokens.append(token)
        }
        // This Mac and this iPhone always have a place, ahead of devices
        // the stored order does not rank.
        let pinned = [HostSizePolicy.macToken, thisDeviceID.map(HostSizePolicy.deviceToken)].compactMap { $0 }
        let stored = order.filter(HostSizePolicy.isValidToken)
        let room = HostSizePolicy.maxOrder - pinned.filter { !stored.contains($0) }.count
        for token in stored.prefix(max(0, room)) { add(token) }
        add(HostSizePolicy.macToken)
        add(thisDeviceID.map(HostSizePolicy.deviceToken))
        for participant in state?.participants ?? [] { add(token(of: participant)) }
        return tokens.map { token in
            OrderRow(token: token, title: orderTitle(token), symbol: orderSymbol(token))
        }
    }

    private func participant(for token: String) -> TerminalSizeParticipant? {
        guard let id = HostSizePolicy.deviceID(fromToken: token) else { return nil }
        return state?.participants.first { $0.deviceID == id && !macParticipants.contains($0.id) }
    }

    private func orderTitle(_ token: String) -> String {
        if token == HostSizePolicy.macToken { return "This Mac" }
        if let id = HostSizePolicy.deviceID(fromToken: token), id == thisDeviceID { return "This iPhone" }
        if let participant = participant(for: token) { return title(of: participant) }
        return "Another device"
    }

    private func orderSymbol(_ token: String) -> String {
        if token == HostSizePolicy.macToken { return "laptopcomputer" }
        if let id = HostSizePolicy.deviceID(fromToken: token), id == thisDeviceID { return "iphone" }
        return participant(for: token).map { Self.symbol(kind: $0.deviceKind) } ?? "display"
    }

    /// The order after moving the shown rows (`onMove`).
    public static func reordered(_ rows: [OrderRow], from source: IndexSet, to destination: Int) -> [String] {
        var tokens = rows.map(\.token)
        let moving = source.sorted().map { tokens[$0] }
        for index in source.sorted(by: >) { tokens.remove(at: index) }
        let before = source.filter { $0 < destination }.count
        tokens.insert(contentsOf: moving, at: destination - before)
        return tokens
    }
}
