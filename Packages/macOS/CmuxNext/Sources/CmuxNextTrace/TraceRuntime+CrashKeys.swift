import CmuxNextCompat

/// The process's crash-key page (task 078): ``TraceBlackBox`` makes it and attaches it once, and every
/// ``setCrashKey(_:_:)`` of the process stores into it from then on.
extension TraceRuntime {
    /// Points ``setCrashKey(_:_:)`` at `page`, the process's crash-key page. Its owner (`TraceBlackBox`) attaches
    /// it once, right after making it; until then a key goes nowhere.
    ///
    /// - Returns: false when a page was attached already (the first one stays).
    @discardableResult
    public func attachCrashKeys(_ page: CrashKeyPage) -> Bool {
        let retained = Unmanaged.passRetained(page)
        let address = UInt64(UInt(bitPattern: retained.toOpaque()))
        guard crashKeysAddress.compareExchange(expected: 0, desired: address, ordering: .acquiringAndReleasing).exchanged else {
            retained.release()
            return false
        }
        return true
    }

    /// The attached crash-key page, nil until ``attachCrashKeys(_:)``.
    public var crashKeys: CrashKeyPage? {
        UnsafeRawPointer(bitPattern: UInt(crashKeysAddress.load(ordering: .acquiring))).map {
            Unmanaged<CrashKeyPage>.fromOpaque($0).takeUnretainedValue()
        }
    }

    /// Stores `value` in a crash-key slot (one relaxed store into the attached page; none before one is).
    public func setCrashKey(_ slot: CrashKeySlot, _ value: UInt64) {
        guard let raw = UnsafeRawPointer(bitPattern: UInt(crashKeysAddress.load(ordering: .acquiring))) else { return }
        Unmanaged<CrashKeyPage>.fromOpaque(raw)._withUnsafeGuaranteedRef { $0.set(slot, value) }
    }

    /// The value a crash-key slot holds now (0 when never set or before a page is attached).
    public func crashKey(_ slot: CrashKeySlot) -> UInt64 {
        guard let raw = UnsafeRawPointer(bitPattern: UInt(crashKeysAddress.load(ordering: .acquiring))) else { return 0 }
        return Unmanaged<CrashKeyPage>.fromOpaque(raw)._withUnsafeGuaranteedRef { $0.value(slot) }
    }
}
