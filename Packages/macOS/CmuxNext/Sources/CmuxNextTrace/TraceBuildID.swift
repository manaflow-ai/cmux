import MachO

extension TraceRing.Identity {
    /// The `LC_UUID` of the process's main executable as 16 bytes, all zero when it has none: the header's
    /// `build_uuid`, so a ring names the exact binary that symbolizes it (Crashpad keys modules by the same
    /// id, third_party/crashpad/crashpad/snapshot/mac/module_snapshot_mac.cc). It reads the load commands of
    /// the mapped image, with no system call, as Rust's `cmux_trace::build_uuid` does.
    public static func mainImageBuildUUID() -> [UInt8] {
        let none = [UInt8](repeating: 0, count: 16)
        guard let header = _dyld_get_image_header(0) else { return none }
        let base = UnsafeRawPointer(header)
        let magic64: UInt32 = 0xFEED_FACF
        let uuidCommand: UInt32 = 0x1B
        let headerBytes = 32
        guard base.loadUnaligned(as: UInt32.self) == magic64 else { return none }
        let count = Int(base.loadUnaligned(fromByteOffset: 16, as: UInt32.self))
        let end = headerBytes + Int(base.loadUnaligned(fromByteOffset: 20, as: UInt32.self))
        var offset = headerBytes
        for _ in 0 ..< count {
            guard offset + 8 <= end else { return none }
            let command = base.loadUnaligned(fromByteOffset: offset, as: UInt32.self)
            let size = Int(base.loadUnaligned(fromByteOffset: offset + 4, as: UInt32.self))
            if command == uuidCommand, size >= 24, offset + 24 <= end {
                return (0 ..< 16).map { base.load(fromByteOffset: offset + 8 + $0, as: UInt8.self) }
            }
            guard size >= 8 else { return none }
            offset += size
        }
        return none
    }
}
