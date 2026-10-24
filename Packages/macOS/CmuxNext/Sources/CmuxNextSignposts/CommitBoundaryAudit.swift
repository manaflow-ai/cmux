import CoreFoundation
import Foundation

/// The main run loop's display, layout and commit observers, checked against ``CommitBoundary``.
///
/// ``CommitBoundary`` is right only while every observer that lays out, displays or commits the
/// turn runs at an order below ``CommitBoundary/order``. The audit judges observers by position, not
/// by name: a block observer (`CFRunLoopObserverCreateWithHandler`, SwiftUI's update cycle, an AppKit
/// observer on a later major) prints as a trampoline (`__CFRunLoopObserverCreateWithHandler_block_invoke`,
/// `???`), so every observer after the boundary at before-waiting or exit is late, except the
/// boundary's own order and the autorelease pool pop at INT_MAX: Core Animation's transaction observer and
/// AppKit's own (its display cycle, constraint and layout passes). Which observers exist, and
/// their orders, belong to the macOS major, so this reads them from the running process
/// (`CFCopyDescription` of the run loop) instead of assuming: `SignpostsTests` checks a bare test process,
/// an App test checks one with `NSApplication` and a window, and the App's `debug.commit_boundary`
/// socket command reports the running app on any fleet host (macOS 14, 15, 26, 27).
///
/// ```swift
/// let audit = CommitBoundaryAudit.mainRunLoop()
/// precondition(audit.late.isEmpty, "\(audit.late)")
/// ```
public nonisolated struct CommitBoundaryAudit: Sendable, Hashable {
    /// Every observer of the dump, each once (a dump lists an observer once per mode), by order.
    public var observers: [CommitBoundaryObserver]

    /// Reads `description`, a `CFCopyDescription` dump of a run loop.
    ///
    /// - Parameter description: The dump (`order = 2000000, callout = _ZN2CA11Transaction...`).
    public init(description: String) {
        observers = Self.observers(in: description).sorted()
    }

    /// The main run loop's audit now.
    @MainActor
    public static func mainRunLoop() -> CommitBoundaryAudit {
        CommitBoundaryAudit(description: CFCopyDescription(CFRunLoopGetMain()) as String)
    }

    /// Core Animation's commit observers among ``observers``.
    public var coreAnimation: [CommitBoundaryObserver] { observers.filter(\.isCoreAnimation) }

    /// The observers that run after ``CommitBoundary`` in the same pass, whatever their callout is
    /// called: each one makes `action.commit` end before its work. Not late: an observer at the
    /// boundary's own order (the boundary, or a tie whose order CFRunLoop leaves to insertion) and the
    /// reviewed observers that draw and commit nothing (``CommitBoundaryObserver/isReviewedAfterBoundary``).
    /// Empty when the boundary is right on this macOS.
    public var late: [CommitBoundaryObserver] {
        observers.filter { $0.order > CommitBoundary.order && $0.firesAtTheBoundary && !$0.isReviewedAfterBoundary }
    }

    private static func observers(in description: String) -> Set<CommitBoundaryObserver> {
        let fields = #"(?:activities = (0x[0-9a-fA-F]+),[^{}]*?)?order = (-?\d+), callout = ([^\s(]+)"#
        guard let regex = try? NSRegularExpression(pattern: fields) else { return [] }
        var found: Set<CommitBoundaryObserver> = []
        // One entry per observer: from its `<CFRunLoopObserver` to the next one or the end of its line.
        for entry in description.components(separatedBy: "<CFRunLoopObserver").dropFirst() {
            let text = "<CFRunLoopObserver" + (entry.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? entry)
            let trimmed = text.trimmingCharacters(in: CharacterSet(charactersIn: "\",) \t"))
            let range = NSRange(trimmed.startIndex..., in: trimmed)
            guard let match = regex.firstMatch(in: trimmed, range: range),
                  let orderRange = Range(match.range(at: 2), in: trimmed),
                  let calloutRange = Range(match.range(at: 3), in: trimmed),
                  let order = Int(trimmed[orderRange]) else { continue }
            let activities = Range(match.range(at: 1), in: trimmed).flatMap { UInt(trimmed[$0].dropFirst(2), radix: 16) }
            found.insert(CommitBoundaryObserver(order: order, callout: String(trimmed[calloutRange]), activities: activities,
                                                dumpText: trimmed))
        }
        return found
    }
}
