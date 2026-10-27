#if DEBUG || CMUX_BENCH_HOOKS
// The Chromium host app ships in Debug builds only (embed-cef.sh), and so does its Swift side.
import CmuxNextSharedRegionC
import Darwin

/// Why an input ring could not be made or mapped.
nonisolated enum ChromiumHostInputRingError: Error, Equatable, Sendable {
    /// The shared memory region could not be made (errno).
    case region(Int32)
    /// The region could not be mapped (errno).
    case map(Int32)
    /// The descriptor holds no ring of this layout.
    case notARing
}

/// A new input ring before the host's spawn: the region the spawner passes on
/// the host's fd ``ChromiumHostInputRing/hostDescriptor`` and the doorbell's
/// name it passes in ``arguments``. The supervisor's spawn (task 080) owns it
/// and keeps ``fd`` for cmux's writer
/// (``ChromiumHostAttachment/inputRingFD``).
nonisolated struct ChromiumHostInputRingRegion: Sendable {
    static let doorbellArgument = "--input-doorbell="

    /// A read-write, close-on-exec descriptor of the formatted region.
    let fd: Int32
    /// The bootstrap name the host checks the doorbell in under.
    let doorbellName: String

    var arguments: [String] { [Self.doorbellArgument + doorbellName] }

    /// A zeroed, formatted region and a fresh doorbell name.
    static func make() throws(ChromiumHostInputRingError) -> ChromiumHostInputRingRegion {
        let fd = cmux_input_ring_region_create(ChromiumHostInputRing.ringBytes)
        guard fd >= 0 else { throw .region(errno) }
        // SAFETY: a mapping of the region's `ringBytes`, the size it was created with; `format` writes only its
        // header, inside them, and the mapping is unmapped once right after.
        guard let base = unsafe mmap(nil, ChromiumHostInputRing.ringBytes, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0),
              unsafe base != UnsafeMutableRawPointer(bitPattern: -1) else {
            let error = errno
            Darwin.close(fd)
            throw .map(error)
        }
        unsafe ChromiumHostInputRing.format(base)
        unsafe munmap(base, ChromiumHostInputRing.ringBytes)
        let token = UInt64.random(in: .min ... .max)
        return ChromiumHostInputRingRegion(
            fd: fd, doorbellName: "com.cmuxterm.chromium-host.input.\(getpid()).\(String(token, radix: 16))")
    }
}
#endif
