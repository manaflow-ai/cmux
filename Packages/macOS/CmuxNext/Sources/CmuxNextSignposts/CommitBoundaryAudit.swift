import CoreFoundation
import Foundation

/// The main run loop's display, layout and commit observers, checked against ``CommitBoundary``.
///
/// ``CommitBoundary`` is right only while every observer that lays out, displays or commits the
/// turn runs at an order below ``CommitBoundary/order``: Core Animation's transaction observer and
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
    /// The display, layout and commit observers found (Core Animation's and AppKit's), each once
    /// (a dump lists an observer once per mode), by order.
    public var observers: [CommitBoundaryObserver]

    /// Reads `description`, a `CFCopyDescription` dump of a run loop.
    ///
    /// - Parameter description: The dump (`order = 2000000, callout = _ZN2CA11Transaction...`).
    public init(description: String) {
        observers = Self.observers(in: description).filter(Self.isDisplayOrCommit).sorted()
    }

    /// The main run loop's audit now.
    @MainActor
    public static func mainRunLoop() -> CommitBoundaryAudit {
        CommitBoundaryAudit(description: CFCopyDescription(CFRunLoopGetMain()) as String)
    }

    /// Core Animation's commit observers among ``observers``.
    public var coreAnimation: [CommitBoundaryObserver] { observers.filter(\.isCoreAnimation) }

    /// The observers that would run after ``CommitBoundary`` in the same pass: each one makes
    /// `action.commit` end before that observer's layout, display or commit. Empty when the
    /// boundary is right on this macOS.
    public var late: [CommitBoundaryObserver] {
        observers.filter { $0.order >= CommitBoundary.order && $0.firesAtTheBoundary }
    }

    /// Callouts of Core Animation's transaction observer and of AppKit's display cycle, layout,
    /// constraint and display passes, by the words their symbols use.
    private static func isDisplayOrCommit(_ observer: CommitBoundaryObserver) -> Bool {
        if observer.isCoreAnimation { return true }
        let callout = observer.callout.lowercased()
        return ["display", "layout", "constraint", "commit", "transaction"].contains { callout.contains($0) }
    }

    private static func observers(in description: String) -> Set<CommitBoundaryObserver> {
        let pattern = #"(?:activities = (0x[0-9a-fA-F]+),[^{}]*?)?order = (-?\d+), callout = ([^\s(]+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(description.startIndex..., in: description)
        var found: Set<CommitBoundaryObserver> = []
        for match in regex.matches(in: description, range: range) {
            guard let orderRange = Range(match.range(at: 2), in: description),
                  let calloutRange = Range(match.range(at: 3), in: description),
                  let order = Int(description[orderRange]) else { continue }
            let activities = Range(match.range(at: 1), in: description).flatMap { UInt(description[$0].dropFirst(2), radix: 16) }
            found.insert(CommitBoundaryObserver(order: order, callout: String(description[calloutRange]), activities: activities))
        }
        return found
    }
}
