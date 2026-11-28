public import Foundation

/// `TerminalSizeState`, `TerminalSizePolicy` and `TerminalSizeParticipant` are generated from the schema's
/// `SizeState`, `SizePolicy` and `SizeParticipant` (swift_app/bindings.json, Terminals family).
extension TerminalSizeState {
    public typealias Grid = CellSize
    public typealias Policy = TerminalSizePolicy
    public typealias Participant = TerminalSizeParticipant

    /// What view `me` shows about the grid: nil while it sets the grid itself, when nobody does
    /// (outside `fixed`), or when the grid already fits it (nothing is padded or cropped, so
    /// nothing needs saying).
    public func notice(for me: String?) -> TerminalSizeNotice? {
        guard let me, let mine = participants.first(where: { $0.id == me }), !owners.contains(me) else { return nil }
        if let viewport = mine.viewport, viewport.cols == cols, viewport.rows == rows { return nil }
        guard let ownerID = owners.first, let owner = participants.first(where: { $0.id == ownerID }) else {
            // A fixed grid has no owner; the view still says why it is padded or cropped.
            guard policy?.mode == "fixed" else { return nil }
            return TerminalSizeNotice(ownerName: nil, ownerKind: nil, sameDevice: false, cols: cols, rows: rows,
                                      mode: policy?.mode, reason: reason, fixedSize: true)
        }
        let sameDevice = owner.deviceKind == mine.deviceKind && owner.deviceName != nil
            && owner.deviceName == mine.deviceName
        return TerminalSizeNotice(ownerName: owner.deviceName ?? owner.displayName, ownerKind: owner.deviceKind,
                                  sameDevice: sameDevice, cols: cols, rows: rows, mode: policy?.mode, reason: reason)
    }
}

/// "Sized for <device> · cols×rows": another view sets this terminal's grid and it does not fit
/// this view. `sameDevice`: the owner is another view on this device (another window of this Mac).
public struct TerminalSizeNotice: Sendable, Hashable {
    public var ownerName: String?
    public var ownerKind: String?
    public var sameDevice: Bool
    public var cols: Int
    public var rows: Int
    /// The policy that chose the owner (nil from a daemon that does not say: last active).
    public var mode: String?
    /// The size state's `reason`.
    public var reason: String?
    /// The grid is fixed: no view sets it.
    public var fixedSize: Bool

    public init(ownerName: String?, ownerKind: String?, sameDevice: Bool, cols: Int, rows: Int, mode: String?,
                reason: String? = nil, fixedSize: Bool = false) {
        self.ownerName = ownerName
        self.ownerKind = ownerKind
        self.sameDevice = sameDevice
        self.cols = cols
        self.rows = rows
        self.mode = mode
        self.reason = reason
        self.fixedSize = fixedSize
    }

    /// A claim alone moves the grid only under last active, or under `priority` while no ranked
    /// view counts (`priority-fallback`). Otherwise Take over sets the terminal to last active first.
    public var takeOverSetsLatest: Bool {
        guard let mode, mode != "latest" else { return false }
        return !(mode == "priority" && reason == "priority-fallback")
    }
}

/// This client's device as the shared-sizing engine sees it (`set-client-info`).
public struct TerminalSizingDevice: Sendable, Hashable {
    public var kind: String
    public var name: String?

    public init(kind: String, name: String?) {
        self.kind = kind
        self.name = name
    }
}
