#if DEBUG || CMUX_BENCH_HOOKS
import AppKit

/// Where a dirtied view lies from the turn's target.
nonisolated enum InputDirtyRelation: String, Sendable {
    /// The target or a view inside it.
    case target
    /// A view that holds the target: its layout or display may follow from the target's change.
    case ancestor
    /// Another view of the target's window.
    case outside
    case otherWindow = "other_window"
    /// A layer that no view hosts.
    case noView = "no_view"
    /// The event had no target view (a key with the window as first responder).
    case noTarget = "no_target"

    /// Main actor: it walks the views' hierarchy and reads their windows.
    @MainActor
    init(of view: NSView?, to target: NSView?) {
        guard let view else { self = .noView; return }
        guard let target else { self = .noTarget; return }
        if view === target || view.isDescendant(of: target) {
            self = .target
        } else if view.window !== target.window {
            self = .otherWindow
        } else {
            self = target.isDescendant(of: view) ? .ancestor : .outside
        }
    }

    /// Work outside the target's subtree and its ancestors: MQ-input-dirty-views' rows.
    var isOffTarget: Bool { self == .outside || self == .otherWindow || self == .noView }
}

/// The sites and turns since launch or since the last reset.
nonisolated struct InputDirtyWindow: Sendable {
    var sites: [Key: Site] = [:]
    var sitesOverflow = 0
    var calls = 0
    var offTargetCalls = 0
    var turns: [InputDirtyTurnKind: Int] = [:]
    /// The newest turns, at most the ledger's turn limit; ``nextPass`` is the oldest once full.
    var passes: [Pass] = []
    var nextPass = 0

    /// One site's key: the call, the receiver's class, its relation and its stack's innermost frames.
    nonisolated struct Key: Hashable, Sendable {
        let call: InputDirtyCall
        let receiverClass: ObjectIdentifier
        let relation: InputDirtyRelation
        let stack: Int
    }

    /// One site's calls, with the first call's stack.
    nonisolated struct Site: Sendable {
        let call: InputDirtyCall
        let objectClass: String
        let viewClass: String?
        let relation: InputDirtyRelation
        var count = 0
        var kinds: Set<InputDirtyTurnKind> = []
        let stack: [UInt]

        init(call: InputDirtyCall, objectClass: String, viewClass: String?, relation: InputDirtyRelation, stack: [UInt]) {
            self.call = call
            self.objectClass = objectClass
            self.viewClass = viewClass
            self.relation = relation
            self.stack = stack
        }
    }

    /// One ended turn.
    nonisolated struct Pass: Sendable, Equatable {
        let kind: InputDirtyTurnKind
        /// The commit pass that ended it.
        let nanos: UInt64
        let calls: Int
        let offTarget: Int
    }

    mutating func add(_ key: Key, kind: InputDirtyTurnKind, limit: Int, new: () -> Site) {
        calls += 1
        if key.relation.isOffTarget { offTargetCalls += 1 }
        if sites[key] == nil {
            guard sites.count < limit else {
                sitesOverflow += 1
                return
            }
            sites[key] = new()
        }
        sites[key]?.count += 1
        sites[key]?.kinds.insert(kind)
    }

    mutating func end(_ pass: Pass, limit: Int) {
        turns[pass.kind, default: 0] += 1
        if passes.count < limit {
            passes.append(pass)
        } else {
            passes[nextPass] = pass
            nextPass = (nextPass + 1) % limit
        }
    }
}

/// One window of the ledger, copied on the main thread for the off-main read.
public nonisolated struct InputDirtyCopy: Sendable {
    let installed: Bool
    let installedNow: Bool
    let sinceLaunch: Bool
    let window: InputDirtyWindow
    let siteLimit: Int
    let turnLimit: Int
}
#endif
