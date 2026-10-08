// SPDX-License-Identifier: GPL-3.0-or-later
@testable import CmuxCuaHelperCore
import Darwin
import Foundation
import Testing

@Suite struct KernelPeerInspectorTests {
    @Test func socketPairPeerIsThisProcessWithItsParentChain() throws {
        var pair: [Int32] = [-1, -1]
        #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0)
        defer { close(pair[0]); close(pair[1]) }
        let facts = try #require(KernelPeerInspector().facts(forConnection: pair[0], requirement: nil))
        #expect(facts.uid == geteuid())
        #expect(facts.stamp.pid == getpid())
        #expect(facts.stamp == KernelPeerInspector.stamp(getpid()))
        #expect(facts.ancestors.first?.pid == getppid())
    }

    @Test func stampChangesMeaningWhenThePidIsGone() {
        #expect(KernelPeerInspector.stamp(pid_t(Int32.max - 7)) == nil)
    }
}
