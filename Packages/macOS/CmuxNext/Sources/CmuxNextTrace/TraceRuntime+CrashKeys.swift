/// The process's crash-key page (task 078): ``TraceBlackBox`` makes it and attaches it once, and every
/// ``setCrashKey(_:_:)`` of the process stores into it from then on.
extension TraceRuntime {
    /// Points ``setCrashKey(_:_:)`` at `page`, the process's crash-key page. Its owner (`TraceBlackBox`) attaches
    /// it once, right after making it; until then a key goes nowhere.
    ///
    /// - Returns: false when a page was attached already (the first one stays).
    @discardableResult
    public func attachCrashKeys(_ page: CrashKeyPage) -> Bool {
        crashKeyPage.attach(page)
    }

    /// The attached crash-key page, nil until ``attachCrashKeys(_:)``.
    public var crashKeys: CrashKeyPage? { crashKeyPage.page }

    /// Stores `value` in a crash-key slot of the attached page (none before one is).
    public func setCrashKey(_ slot: CrashKeySlot, _ value: UInt64) {
        crashKeyPage.set(slot, value)
    }

    /// The value a crash-key slot holds now (0 when never set or before a page is attached).
    public func crashKey(_ slot: CrashKeySlot) -> UInt64 {
        crashKeyPage.value(slot)
    }
}
