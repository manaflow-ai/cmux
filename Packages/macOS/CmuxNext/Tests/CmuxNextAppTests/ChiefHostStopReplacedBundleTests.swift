import Foundation
import Testing
@testable import CmuxNextHomeEngine

/// A Chief host whose bundle an update replaced stays stoppable: `proc_pidpath` fails for it,
/// so its kernel process name decides.
struct ChiefHostStopReplacedBundleTests {
    @Test func aHostIsKnownByItsPath() {
        #expect(ChiefHostStop.isChiefHost(path: "/Applications/cmux NIGHTLY.app/Contents/Resources/bin/optchat-chief", processName: nil))
        #expect(!ChiefHostStop.isChiefHost(path: "/Applications/cmux NIGHTLY.app/Contents/Resources/bin/acpmux", processName: "optchat-chief"))
    }

    @Test func aHostWhoseFileIsGoneIsKnownByItsName() {
        #expect(ChiefHostStop.isChiefHost(path: nil, processName: "optchat-chief"))
        #expect(!ChiefHostStop.isChiefHost(path: nil, processName: "cmux"))
        #expect(!ChiefHostStop.isChiefHost(path: nil, processName: nil))
    }

    @Test func thisProcessHasAName() {
        #expect(ChiefHostStop.processName(getpid())?.isEmpty == false)
    }
}
