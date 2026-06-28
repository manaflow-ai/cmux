public import AppKit
import Foundation

/// Process-wide refcounted access to `NSWindow.acceptsMouseMovedEvents`.
///
/// Several unrelated AppKit surfaces (the minimal-mode titlebar event surface,
/// the window-decorations controller, and the update titlebar accessory) each
/// want mouse-moved events delivered for the same window. They are independent
/// views with no common owner, so the enable/disable bookkeeping has to live in
/// one process-wide registry: the window's original `acceptsMouseMovedEvents`
/// value is restored only once the LAST owner releases it. Splitting this into
/// per-caller instances would let the first owner to release restore the window
/// while another owner still needs mouse-moved events, an observable behavior
/// change, so the single shared registry is load-bearing and is exposed as
/// ``shared``.
///
/// Faithful lift of the app-target caseless-enum `WindowMouseMovedEventsCoordinator`:
/// the former `nonisolated(unsafe) static` records dictionary and `NSLock` are
/// now instance state on the one shared registry, with identical refcounting.
///
/// `@unchecked Sendable` is justified: the mutable `records` dictionary is
/// guarded by `lock` on every access, and the methods run both on AppKit's
/// main-thread event-dispatch path and from nonisolated `deinit` cleanup (which
/// cannot hop to an actor), so a lock-guarded reference type is required rather
/// than `@MainActor` isolation.
public final class WindowMouseMovedEventsCoordinator: @unchecked Sendable {
    /// The single process-wide registry. See the type doc for why a shared
    /// instance (rather than constructor injection) is required: the three
    /// callers have no common owner and the refcount must span all of them.
    public static let shared = WindowMouseMovedEventsCoordinator()

    private struct Record {
        weak var window: NSWindow?
        let previousValue: Bool
        var owners: Set<ObjectIdentifier>
    }

    private var records: [ObjectIdentifier: Record] = [:]
    private let lock = NSLock()

    /// Creates an empty registry. Use ``shared`` for the process-wide instance;
    /// a fresh instance only refcounts its own owners.
    public init() {}

    /// Registers `owner` as wanting mouse-moved events for `window`, enabling
    /// `acceptsMouseMovedEvents` and recording the window's prior value on the
    /// first owner.
    public func enable(for window: NSWindow, owner: AnyObject) {
        lock.lock()
        defer { lock.unlock() }

        let windowKey = ObjectIdentifier(window)
        let ownerKey = ObjectIdentifier(owner)
        if var record = records[windowKey] {
            record.owners.insert(ownerKey)
            records[windowKey] = record
        } else {
            records[windowKey] = Record(
                window: window,
                previousValue: MainActor.assumeIsolated { window.acceptsMouseMovedEvents },
                owners: [ownerKey]
            )
        }
        MainActor.assumeIsolated { window.acceptsMouseMovedEvents = true }
    }

    /// Releases `owner`'s interest in mouse-moved events for `window`, restoring
    /// the window's prior `acceptsMouseMovedEvents` value once no owner remains.
    public func disable(for window: NSWindow, owner: AnyObject) {
        lock.lock()
        defer { lock.unlock() }

        let windowKey = ObjectIdentifier(window)
        guard var record = records[windowKey] else { return }
        record.owners.remove(ObjectIdentifier(owner))
        if record.owners.isEmpty {
            MainActor.assumeIsolated { record.window?.acceptsMouseMovedEvents = record.previousValue }
            records.removeValue(forKey: windowKey)
        } else {
            records[windowKey] = record
        }
    }

    /// Releases `owner` from every window it registered for, restoring each
    /// window's prior value when it becomes the last owner there.
    public func disableOwner(_ owner: AnyObject) {
        lock.lock()
        defer { lock.unlock() }

        let ownerKey = ObjectIdentifier(owner)
        for windowKey in Array(records.keys) {
            guard var record = records[windowKey] else { continue }
            record.owners.remove(ownerKey)
            if record.owners.isEmpty {
                MainActor.assumeIsolated { record.window?.acceptsMouseMovedEvents = record.previousValue }
                records.removeValue(forKey: windowKey)
            } else {
                records[windowKey] = record
            }
        }
    }
}
