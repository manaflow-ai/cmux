@testable import CmuxNextControl
import Foundation
import Testing

/// `cmux surface size`, `size-policy`, `size-to-me`, `disconnect-others`,
/// `size-counts`, `disconnect-participant` and `participants`
/// (CLI/CMUXCLI+SurfaceSizing.swift, from main's shared terminal sizing)
/// call these methods. cmux-next does not serve them yet (cmux-tui-contract.md
/// section 9), so each answers a typed `unsupported` error that names shared
/// terminal sizing, not the generic "terminal operation" reason.
struct SurfaceSizingUnsupportedTests {
    static let methods = ["terminal.size_state", "terminal.size_policy.set", "terminal.size_counts.set",
                          "terminal.size_to_me", "terminal.participants.disconnect_others",
                          "terminal.participant.disconnect"]

    @Test(arguments: methods)
    func sizingMethodsAnswerTypedUnsupported(_ method: String) throws {
        let error = try #require(CompatService.unsupportedError(for: method))
        #expect(error.code == "unsupported")
        #expect(error.message == "unsupported in cmux-next: shared terminal sizing is not in cmux-next yet; the newest active view sets the grid")
        #expect(error.data == .object(["reason": .string("shared terminal sizing is not in cmux-next yet; the newest active view sets the grid"),
                                       "method": .string(method)]))
    }
}
