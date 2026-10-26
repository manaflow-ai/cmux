nonisolated extension Array where Element == UInt8 {
    /// Appends `value` least significant byte first (the wire's order, `chromium_host_wire.h`), with no
    /// pointer view of the value.
    mutating func appendLittleEndian<Value: FixedWidthInteger>(_ value: Value) {
        for shift in stride(from: 0, to: Value.bitWidth, by: 8) {
            append(UInt8(truncatingIfNeeded: value >> shift))
        }
    }
}
