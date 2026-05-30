// SPDX-License-Identifier: MIT

import Foundation

/// Cheap FNV-1a 64-bit digest over a ``CellGrid``'s codepoints and
/// cursor position. Used by ``SnapshotPoller`` (D8) to suppress
/// snapshot emission when nothing visible has changed since the last
/// tick.
///
/// NOT a cryptographic hash; collisions are acceptable because the
/// worst case is "we emit one extra snapshot".
public enum CellGridDigest {
    private static let fnvOffset: UInt64 = 0xCBF2_9CE4_8422_2325
    private static let fnvPrime:  UInt64 = 0x0000_0100_0000_01B3

    /// Returns a 64-bit FNV-1a digest of the grid's visible content +
    /// cursor + per-row wrap flags.
    public static func compute(_ grid: CellGrid) -> UInt64 {
        var h: UInt64 = fnvOffset
        mix(&h, UInt64(grid.cols))
        mix(&h, UInt64(grid.rows))
        mix(&h, grid.altScreen ? 1 : 0)
        mix(&h, UInt64(grid.cursor.row))
        mix(&h, UInt64(grid.cursor.col))
        mix(&h, grid.cursor.visible ? 1 : 0)
        mix(&h, UInt64(grid.cursor.style.hashValue & 0xFFFF))
        for row in grid.rowsData {
            mix(&h, row.wrap ? 1 : 0)
            mix(&h, row.wrapContinuation ? 1 : 0)
            for cell in row.cells {
                for s in cell.t.unicodeScalars {
                    mixByte(&h, UInt8(s.value & 0xFF))
                    mixByte(&h, UInt8((s.value >> 8) & 0xFF))
                    mixByte(&h, UInt8((s.value >> 16) & 0xFF))
                    mixByte(&h, UInt8((s.value >> 24) & 0xFF))
                }
                mix(&h, UInt64(cell.wide.hashValue & 0xFF))
            }
        }
        return h
    }

    @inline(__always)
    private static func mix(_ h: inout UInt64, _ v: UInt64) {
        for shift in stride(from: 0, through: 56, by: 8) {
            mixByte(&h, UInt8((v >> shift) & 0xFF))
        }
    }

    @inline(__always)
    private static func mixByte(_ h: inout UInt64, _ b: UInt8) {
        h ^= UInt64(b)
        h &*= fnvPrime
    }
}
