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

    // Device tokens of the priority order (`mobile.terminalSizingOrder`):
    // Rust's terminal_sizing_view (host_size_token_valid, host_size_device_token).

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

#if os(iOS)
import CmuxMobileLinkFFI

/// What the Connected Devices sheet and the Settings page draw. The rules
/// (who each viewer is, why the grid has its size, the priority list) are
/// Rust's terminal_sizing_view; this only hands it the state.
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

    private var input: SizingViewInput {
        SizingViewInput(
            hasState: state != nil,
            reason: state?.reason ?? "",
            owners: state?.owners ?? [],
            participants: (state?.participants ?? []).map(Self.sizing),
            selfParticipant: selfParticipant,
            macParticipants: macParticipants.sorted(),
            thisDeviceId: thisDeviceID
        )
    }

    private static func sizing(_ participant: TerminalSizeParticipant) -> SizingParticipant {
        SizingParticipant(
            id: participant.id, deviceKind: participant.deviceKind, deviceName: participant.deviceName,
            displayName: participant.displayName, deviceId: participant.deviceID,
            viewport: participant.viewport.map { SizingGrid(cols: UInt32(clamping: $0.cols), rows: UInt32(clamping: $0.rows)) }
        )
    }

    public func title(of participant: TerminalSizeParticipant) -> String {
        terminalSizingTitle(input: input, participant: Self.sizing(participant))
    }

    /// One row per connected viewer, in attach order.
    public var rows: [Row] {
        terminalSizingRows(input: input).map {
            Row(id: $0.id, title: $0.title, detail: $0.detail, setsSize: $0.setsSize, symbol: $0.symbol)
        }
    }

    /// `120 × 40`.
    public var gridTitle: String? {
        state.map { "\($0.grid.cols) × \($0.grid.rows)" }
    }

    /// Why the grid has its size.
    public var reasonText: String? { terminalSizingReason(input: input) }

    /// The priority list to show: the stored order first, then every viewer
    /// not in it (this Mac and this iPhone first).
    public func orderRows(_ order: [String]) -> [OrderRow] {
        terminalSizingOrderRows(input: input, order: order).map {
            OrderRow(token: $0.token, title: $0.title, symbol: $0.symbol)
        }
    }

    /// The order after moving the shown rows (`onMove`).
    public static func reordered(_ rows: [OrderRow], from source: IndexSet, to destination: Int) -> [String] {
        terminalSizingReordered(tokens: rows.map(\.token), from: source.map { UInt32(clamping: $0) },
                                to: UInt32(clamping: destination))
    }
}
#endif
