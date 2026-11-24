#if canImport(CCmuxInteractivityFFI)
import CCmuxInteractivityFFI
#endif
public import AppKit
public import Foundation

/// Priority by interactivity: the app tells the Rust policy (cmux-interactivity) what the person touches and
/// asks it the priority of a class of work. The table and the decay (300-500 ms after the last input) live in
/// Rust; this file only notes events and converts the answer. Where the app FFI does not carry the header yet,
/// notes do nothing and every class keeps ``WorkPriority/bestEffort``.
public enum Interactivity {
    /// What the person is doing (`cmux_interactivity_note`'s kinds).
    public enum Kind: UInt32, Sendable { case drag = 0, typing, scroll, focus }

    /// What a piece of work is for (`cmux_interactivity_qos`'s classes).
    public enum WorkClass: UInt32, Sendable {
        case input = 0, frame, focusedPane, visiblePane, backgroundPane, agentOutputParse, index, sync, maintenance
    }

    /// The person did `kind` now: one atomic store in Rust.
    public static func note(_ kind: Kind) {
        #if canImport(CCmuxInteractivityFFI)
        cmux_interactivity_note(kind.rawValue)
        #endif
    }

    /// The priority the policy gives `workClass` right now.
    public static func priority(_ workClass: WorkClass) -> WorkPriority {
        #if canImport(CCmuxInteractivityFFI)
        switch cmux_interactivity_qos(workClass.rawValue) {
        case 0x21, 0x19: return .userBlocking
        case 0x15: return .userVisible
        case 0x11: return .bestEffort
        case 0x09: return .idle
        default: return .bestEffort
        }
        #else
        return .bestEffort
        #endif
    }

    @MainActor private static var monitor: Any?

    /// Notes keys, scroll and drags (a divider, window or sidebar drag, a selection) of this app's windows,
    /// once. The monitor reads the event type and returns the event untouched.
    @MainActor
    public static func installEventMonitor() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .scrollWheel, .leftMouseDragged]) { event in
            switch event.type {
            case .keyDown: Interactivity.note(.typing)
            case .scrollWheel: Interactivity.note(.scroll)
            default: Interactivity.note(.drag)
            }
            return event
        }
    }
}

extension BackgroundWork {
    /// ``run(_:mayBlock:shutdown:_:)`` at the priority the interactivity policy gives `workClass` right now.
    public func run<T: Sendable>(_ workClass: Interactivity.WorkClass, mayBlock lane: BlockingLane,
                                 shutdown: ShutdownBehavior = .skipOnShutdown,
                                 _ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await run(Interactivity.priority(workClass), mayBlock: lane, shutdown: shutdown, body)
    }
}
