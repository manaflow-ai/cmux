// SPDX-License-Identifier: GPL-3.0-or-later
import Darwin
import Foundation

/// Byte I/O on the helper's raw descriptors (the host control pipe and the
/// client sockets). Every read and write goes through these two functions, so
/// they hold the module's only pointer use for I/O (Chromium's single
/// loop: base::WriteFileDescriptor, base/files/file_util_posix.cc).
extension HelperWire {
    /// read(2) into `buffer`, at most buffer.count bytes. Returns read's result:
    /// the byte count, 0 at end of file, or -1 with errno set.
    static func read(_ descriptor: Int32, into buffer: inout [UInt8]) -> Int {
        let capacity = buffer.count
        // SAFETY: read writes at most `capacity` bytes, the size passed, into `buffer`,
        // which holds that many for the call.
        return unsafe Darwin.read(descriptor, &buffer, capacity)
    }

    /// Writes all of `data` to `descriptor`, retrying after EINTR and short
    /// writes; stops at the first other failure (the peer is gone).
    static func writeAll(_ data: Data, to descriptor: Int32) {
        var rest = [UInt8](data)
        while !rest.isEmpty {
            // SAFETY: write reads at most rest.count bytes, the count passed, from `rest`,
            // which holds that many for the call.
            let written = unsafe Darwin.write(descriptor, rest, rest.count)
            if written < 0, errno == EINTR { continue }
            guard written > 0 else { return }
            rest = Array(rest.dropFirst(written))
        }
    }
}
