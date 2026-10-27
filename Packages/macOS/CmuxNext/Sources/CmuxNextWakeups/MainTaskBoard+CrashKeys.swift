import CmuxNextCompat
public import CmuxNextTrace

extension MainTaskBoard {
    /// Names the running task's owner in `page` from now on (the composition root, once its black box made the
    /// page): ``CrashKeySlot/mainTaskOwner`` holds the owner's stable key while its task or span runs, 0 between
    /// tasks. Set once: a later call is ignored and returns false.
    @discardableResult
    public func attachCrashKeys(_ page: CrashKeyPage) -> Bool {
        crashKeyOwner.attach(page)
    }
}

/// The running main-thread task's owner in the process's crash-key page (plans/cmux-next/chrome-parity/
/// p09-observability.md, task 078), so a crash or a fatal hang names the owner at the next launch, as Chrome's
/// crash keys name the work that runs (components/crash/core/common/crash_key.h).
///
/// It keeps each interned owner's stable key (``CrashKeySlots/stableKey(_:)`` of the name) by index, written once
/// when the board interns the owner (under the board's owners lock), so naming the owner at a task start is a few
/// loads and one relaxed store: no lock, no allocation, no reference counting. The key table is one block allocated
/// in `init` and never resized; owners past ``capacity`` are named 0.
final class MainTaskCrashKeyOwner: Sendable {
    /// The owners whose key is kept.
    static var capacity: Int { 4096 }

    /// The page the owners are named in, from ``attach(_:)`` on.
    private let page = AttachedCrashKeyPage()
    /// The key table's address (``capacity`` words), kept as an integer so the class is `Sendable` with no
    /// unchecked claim; every access goes through ``AtomicPointerSlot``.
    private let keysAddress: UInt

    init() {
        let words = UnsafeMutablePointer<UInt64>.allocate(capacity: Self.capacity)
        words.initialize(repeating: 0, count: Self.capacity)
        keysAddress = UInt(bitPattern: words)
    }

    deinit {
        UnsafeMutablePointer<UInt64>(bitPattern: keysAddress)?.deallocate()
    }

    /// Names owners in `page` from now on; false when a page was attached already (the first one stays).
    func attach(_ page: CrashKeyPage) -> Bool {
        self.page.attach(page)
    }

    /// Keeps the stable key of owner `name`, interned at `index` (ignored past ``capacity``).
    func intern(_ name: String, at index: UInt32) {
        guard Int(index) < Self.capacity else { return }
        slot(Int(index)).store(CrashKeySlots.stableKey(name), ordering: .relaxed)
    }

    /// Stores the key of the owner at `index` (0: no task runs) in the attached page; nothing without a page.
    @inline(__always)
    func name(_ index: UInt32) {
        let key = index != 0 && Int(index) < Self.capacity ? slot(Int(index)).load(ordering: .relaxed) : 0
        page.set(.mainTaskOwner, key)
    }

    @inline(__always)
    private func slot(_ index: Int) -> AtomicPointerSlot {
        // The table is `capacity` words from `init`; both callers check `index` against it.
        AtomicPointerSlot(UnsafeMutablePointer<UInt64>(bitPattern: keysAddress).unsafelyUnwrapped + index)
    }
}
