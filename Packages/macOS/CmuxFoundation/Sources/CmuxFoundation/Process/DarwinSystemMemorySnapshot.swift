import Darwin
import Foundation

/// Host VM measurements. Available memory is an estimate, not macOS pressure.
public struct DarwinSystemMemorySnapshot: Equatable, Sendable {
    /// Free pages expressed in host-page bytes.
    public let freeBytes: UInt64
    /// Free, inactive and speculative pages; an estimate of reclaimable memory.
    public let availableBytes: UInt64
    /// Physical memory occupied by compressed pages.
    public let compressorBytes: UInt64
    /// Logical size of the pages stored in the compressor.
    public let compressedLogicalBytes: UInt64

    /// Reads a full host VM snapshot and releases the temporary host port right.
    /// Fails when host statistics are unavailable.
    public init?() {
        var statistics = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size
        )
        let expectedCount = count
        let host = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, host) }
        let result = withUnsafeMutablePointer(to: &statistics) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(host, HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS, count == expectedCount else { return nil }
        var hostPageSize: vm_size_t = 0
        guard host_page_size(host, &hostPageSize) == KERN_SUCCESS, hostPageSize > 0 else { return nil }
        let pageSize = UInt64(hostPageSize)
        freeBytes = UInt64(statistics.free_count) * pageSize
        availableBytes = (UInt64(statistics.free_count)
            + UInt64(statistics.inactive_count)
            + UInt64(statistics.speculative_count)) * pageSize
        compressorBytes = UInt64(statistics.compressor_page_count) * pageSize
        compressedLogicalBytes = statistics.total_uncompressed_pages_in_compressor * pageSize
    }

    /// Returns numeric diagnostic fields and fixed measurement-source labels.
    /// - Returns: A JSON-compatible dictionary containing no process identity.
    public func payload() -> [String: Any] {
        [
            "source": "host_statistics64.HOST_VM_INFO64",
            "available_source": "free+inactive+speculative",
            "free_bytes": freeBytes,
            "available_bytes": availableBytes,
            "compressor_bytes": compressorBytes,
            "compressed_logical_bytes": compressedLogicalBytes
        ]
    }
}
