import Darwin

/// NULL-terminated `char *[]` that outlives a fork (``LocalPTYTerminalIO``'s argv and environment).
nonisolated final class CStringArray {
    /// SAFETY: `count + 1` slots, each a strdup copy this object owns or the final nil,
    /// allocated in `init` and freed in `deinit`; readers use it while they hold the object.
    @safe let pointer: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>
    private let count: Int

    init(_ strings: [String]) {
        count = strings.count
        // SAFETY: strings.count + 1 slots: every index written below is below that.
        pointer = unsafe UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>.allocate(capacity: strings.count + 1)
        for (index, string) in strings.enumerated() {
            // SAFETY: as above.
            unsafe pointer[index] = strdup(string)
        }
        // SAFETY: as above.
        unsafe pointer[strings.count] = nil
    }

    deinit {
        // SAFETY: frees the `count` copies and the slots `init` allocated, once.
        for index in 0..<count { unsafe free(pointer[index]) }
        // SAFETY: as above.
        unsafe pointer.deallocate()
    }
}
