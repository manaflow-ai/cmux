// SPDX-License-Identifier: GPL-3.0-or-later
@testable import CmuxCuaHelperCore
import Testing

/// `--pointer-glide` refuses malformed arguments before it posts anything (exit 2), so a bench typo never moves the
/// host's pointer. The posting path itself needs a granted app on a display host (hover-instant-bench.py).
@Suite struct PointerGlideTests {
    @Test func malformedArgumentsExitTwoWithoutPosting() {
        let bad: [[String]] = [
            ["helper"],
            ["helper", "--pointer-glide"],
            ["helper", "--pointer-glide", "1", "2", "3", "4"],
            ["helper", "--pointer-glide", "1", "2", "3", "4", "x"],
            ["helper", "--pointer-glide", "1", "2", "3", "4", "0"],
            ["helper", "--pointer-glide", "1", "2", "3", "4", "2.5"],
            ["helper", "--pointer-glide", "1", "2", "3", "4", "5000"],
            ["helper", "--pointer-glide", "1", "2", "3", "4", "5", "--interval-ms", "500"],
            ["helper", "--pointer-glide", "1", "2", "3", "4", "5", "--interval-ms"],
        ]
        for arguments in bad {
            #expect(PointerGlide().main(arguments: arguments) == 2, "\(arguments)")
        }
    }
}
