import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// The system's memory warnings, for the lists and caches that can give memory back: each
/// registers what it drops (a list spills down to a small window, a cache empties), and a
/// warning runs every handler whose owner is still alive. Chrome's Memory Saver, for a phone.
@MainActor
public final class MemoryPressure {
    public static let shared = MemoryPressure()

    private struct Handler {
        weak var owner: AnyObject?
        let relieve: @MainActor () -> Void
    }

    private var handlers: [Handler] = []
    /// Warnings handled since launch (Debug views, measurements).
    public private(set) var warnings = 0
    #if canImport(UIKit)
    private var observer: (any NSObjectProtocol)?
    #endif

    public init(observesSystem: Bool = true) {
        #if canImport(UIKit)
        guard observesSystem else { return }
        observer = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.relieve() }
        }
        #endif
    }

    /// Runs `relieve` on every memory warning while `owner` is alive.
    public func register(_ owner: AnyObject, relieve: @escaping @MainActor () -> Void) {
        handlers.removeAll { $0.owner == nil || $0.owner === owner }
        handlers.append(Handler(owner: owner, relieve: relieve))
    }

    /// A memory warning: every live owner gives back what it can. Tests and the Debug menu call
    /// it directly; the system's warning calls it on the main queue.
    public func relieve() {
        warnings += 1
        handlers.removeAll { $0.owner == nil }
        for handler in handlers { handler.relieve() }
    }

    /// Owners still registered (tests).
    public var registeredCount: Int { handlers.count(where: { $0.owner != nil }) }
}
