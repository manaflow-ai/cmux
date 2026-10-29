// Public: the inlined key stores use the Compat `Atomic` from other modules, and the `UInt: AtomicValue`
// conformance comes from swift-atomics.
public import Atomics
public import CmuxNextCompat

/// The process's crash-key page (``CrashKeyPage``) for an owner made before the page
/// exists: the page is attached once, when its black box makes it, and every key stored from then on goes into it;
/// a key stored before that goes nowhere. Storing reads one pointer and takes no lock and no reference.
///
/// ```swift
/// let keys = AttachedCrashKeyPage()           // the owner, at its init
/// keys.attach(blackBox.crashKeys)             // the composition root, once
/// keys.setCount(.workspaceCount, 12)          // any thread
/// ```
public final class AttachedCrashKeyPage: Sendable {
    /// The attached page (retained once by ``attach(_:)``, released in `deinit`); 0 until then.
    @usableFromInline let address = Atomic<UInt>(0)

    /// No page yet.
    public init() {}

    deinit {
        if let page = UnsafeRawPointer(bitPattern: address.load(ordering: .acquiring)) {
            Unmanaged<CrashKeyPage>.fromOpaque(page).release()
        }
    }

    /// Stores keys into `page` from now on.
    ///
    /// - Returns: false when a page was attached already (the first one stays).
    @discardableResult
    public func attach(_ page: CrashKeyPage) -> Bool {
        let retained = Unmanaged.passRetained(page)
        guard address.compareExchange(expected: 0, desired: UInt(bitPattern: retained.toOpaque()),
                                      ordering: .acquiringAndReleasing).exchanged else {
            retained.release()
            return false
        }
        return true
    }

    /// The attached page, nil until ``attach(_:)``.
    public var page: CrashKeyPage? {
        UnsafeRawPointer(bitPattern: address.load(ordering: .acquiring)).map {
            Unmanaged<CrashKeyPage>.fromOpaque($0).takeUnretainedValue()
        }
    }

    /// Stores `value` in `slot` of the attached page (``CrashKeyPage/set(_:_:)``); nothing before one is attached.
    @inlinable @inline(__always)
    public func set(_ slot: CrashKeySlot, _ value: UInt64) {
        guard let page = UnsafeRawPointer(bitPattern: address.load(ordering: .acquiring)) else { return }
        // The page stays retained while `self` lives (attach retains it once, deinit releases it).
        Unmanaged<CrashKeyPage>.fromOpaque(page)._withUnsafeGuaranteedRef { $0.set(slot, value) }
    }

    /// Stores the bucket of `count` in a count slot of the attached page (``CrashKeyPage/setCount(_:_:)``).
    @inlinable @inline(__always)
    public func setCount(_ slot: CrashKeySlot, _ count: Int) {
        set(slot, CrashKeyPage.countBucket(count))
    }

    /// The value `slot` holds in the attached page (0 when never set or before a page is attached).
    public func value(_ slot: CrashKeySlot) -> UInt64 {
        page?.value(slot) ?? 0
    }
}
