public import Foundation

/// The daemon's shared-sizing state of one terminal (`size-state`, docs/shared-terminal-sizing.md
/// "Size state"): its grid, who sets it, and every view of it. A view reads it only to tell its
/// user who the grid is sized for (plans/cmux-next/sync-ux/DESIGN.md 2.6).
public struct TerminalSizeState: Decodable, Sendable, Hashable {
    public struct Grid: Decodable, Sendable, Hashable {
        public var cols: Int
        public var rows: Int
        public init(cols: Int, rows: Int) {
            self.cols = cols
            self.rows = rows
        }
    }

    public struct Policy: Decodable, Sendable, Hashable {
        /// `latest`, `smallest`, `largest`, `priority` or `fixed`.
        public var mode: String?
    }

    public struct Participant: Decodable, Sendable, Hashable {
        public var id: String
        public var displayName: String?
        /// `mac`, `iphone`, `ipad`, `tui`, `browser`, `linux`, `windows` or `unknown`.
        public var deviceKind: String?
        public var deviceName: String?
        public var viewport: Grid?
        public var counts: Bool?

        public init(id: String, displayName: String? = nil, deviceKind: String? = nil, deviceName: String? = nil,
                    viewport: Grid? = nil, counts: Bool? = nil) {
            self.id = id
            self.displayName = displayName
            self.deviceKind = deviceKind
            self.deviceName = deviceName
            self.viewport = viewport
            self.counts = counts
        }

        enum CodingKeys: String, CodingKey {
            case id, viewport, counts
            case displayName = "display_name", deviceKind = "device_kind", deviceName = "device_name"
        }
    }

    public var generation: UInt64
    public var cols: Int
    public var rows: Int
    public var owners: [String]
    public var policy: Policy?
    /// Why the grid has this size: `latest`, `smallest`, `largest`, `priority`, `fixed`, `held` or
    /// `priority-fallback` (no ranked view counts, so the grid follows activity).
    public var reason: String?
    public var participants: [Participant]

    public init(generation: UInt64, cols: Int, rows: Int, owners: [String], policy: Policy? = nil,
                reason: String? = nil, participants: [Participant]) {
        self.generation = generation
        self.cols = cols
        self.rows = rows
        self.owners = owners
        self.policy = policy
        self.reason = reason
        self.participants = participants
    }

    enum CodingKeys: String, CodingKey {
        case generation, cols, rows, owners, policy, reason, participants
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        generation = try container.decode(UInt64.self, forKey: .generation)
        cols = try container.decode(Int.self, forKey: .cols)
        rows = try container.decode(Int.self, forKey: .rows)
        owners = try container.decodeIfPresent([String].self, forKey: .owners) ?? []
        policy = try container.decodeIfPresent(Policy.self, forKey: .policy)
        reason = try container.decodeIfPresent(String.self, forKey: .reason)
        participants = try container.decodeIfPresent([Participant].self, forKey: .participants) ?? []
    }

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
