import CmuxNextCompat

extension GhosttyTraceHook {
    /// The hook's surfaces by `ghostty_surface_trace_id`: main inserts and removes, any thread looks up, with no
    /// lock and no allocation. Open addressing with linear probing over one fixed allocation; an entry is
    /// the id word (0: never used, ``removed``: free again) and the address of its ``Surface``.
    ///
    /// Ghostty numbers surfaces from 1 and never reuses an id, so surface `n` lands on slot `n % capacity`,
    /// which the surface `capacity` ids before it has usually left: probes stay short. A removed entry keeps
    /// probing past it. The table does not retain a surface: its ``SurfaceBridge`` holds it until after
    /// `ghostty_surface_free` returns, and the id leaves the table before that release
    /// (``GhosttyTraceHook/unregister(id:)``), when no call from another thread for it is running. A lookup
    /// that races an insert or a removal of another id reads that slot's id word first and moves on.
    nonisolated final class SurfaceTable: Sendable {
        /// The id word of a slot whose surface was removed.
        private static let removed = UInt64.max

        /// Slots; a power of two.
        let capacity: Int
        /// The address of the slots' words: slot `i`'s id at word `2i`, its surface's address at `2i + 1`.
        /// Allocated in `init`, freed in `deinit`; kept as an integer so the class is `Sendable` with no unchecked
        /// claim (as `LaneStats`); every access goes through ``AtomicPointerSlot``.
        private let wordsAddress: UInt

        /// A table of `capacity` slots (rounded up to a power of two).
        init(capacity: Int) {
            var size = 1
            while size < capacity { size <<= 1 }
            self.capacity = size
            let words = UnsafeMutablePointer<UInt64>.allocate(capacity: 2 * size)
            words.initialize(repeating: 0, count: 2 * size)
            wordsAddress = UInt(bitPattern: words)
        }

        deinit {
            UnsafeMutablePointer<UInt64>(bitPattern: wordsAddress)?.deallocate()
        }

        /// Word `index`; below `2 * capacity`.
        private func word(_ index: Int) -> AtomicPointerSlot {
            AtomicPointerSlot(UnsafeMutablePointer<UInt64>(bitPattern: wordsAddress).unsafelyUnwrapped + index)
        }

        private func idWord(_ slot: Int) -> AtomicPointerSlot { word(2 * slot) }
        private func surfaceWord(_ slot: Int) -> AtomicPointerSlot { word(2 * slot + 1) }
        private func home(_ id: UInt64) -> Int { Int(truncatingIfNeeded: id & UInt64(capacity - 1)) }

        /// Adds `surface` under `id` (main only; `id` nonzero and not in the table).
        ///
        /// - Returns: false when every slot is taken.
        @MainActor
        func insert(_ surface: Surface, id: UInt64) -> Bool {
            guard id != 0, id != Self.removed else { return false }
            let address = UInt64(UInt(bitPattern: Unmanaged.passUnretained(surface).toOpaque()))
            for step in 0..<capacity {
                let slot = (home(id) + step) & (capacity - 1)
                let current = idWord(slot).load(ordering: .relaxed)
                guard current == 0 || current == Self.removed else { continue }
                surfaceWord(slot).store(address, ordering: .relaxed)
                idWord(slot).store(id, ordering: .releasing) // a lookup that reads the id reads the address
                return true
            }
            return false
        }

        /// Removes `id` (main only).
        @MainActor
        func remove(id: UInt64) {
            guard let slot = slot(of: id) else { return }
            idWord(slot).store(Self.removed, ordering: .releasing)
            surfaceWord(slot).store(0, ordering: .relaxed)
        }

        /// The surface under `id`, read with no reference-count traffic; nil when the table has none.
        // perf-hot: 0.05us terminal-key
        func surface(_ id: UInt64) -> Unmanaged<Surface>? {
            guard let slot = slot(of: id) else { return nil }
            let address = surfaceWord(slot).load(ordering: .relaxed)
            return UnsafeRawPointer(bitPattern: UInt(address)).map { Unmanaged<Surface>.fromOpaque($0) }
        }

        private func slot(of id: UInt64) -> Int? {
            guard id != 0, id != Self.removed else { return nil }
            for step in 0..<capacity {
                let slot = (home(id) + step) & (capacity - 1)
                switch idWord(slot).load(ordering: .acquiring) {
                case id: return slot
                case 0: return nil
                default: continue
                }
            }
            return nil
        }
    }
}
