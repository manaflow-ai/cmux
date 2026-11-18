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

    /// bin/optchat-chief as a link to the multicall bin/cmux (CMUX-570): `proc_pidpath` names
    /// cmux, and argv[0] (the link) tells the Chief from cmux's CLI, daemon or acpmux.
    @Test func aChiefStartedThroughTheCmuxLinkIsKnownByItsArgv0() {
        let bin = "/Applications/cmux NIGHTLY.app/Contents/Resources/bin"
        #expect(ChiefHostStop.isChiefHost(path: "\(bin)/cmux", processName: nil, argv0: "\(bin)/optchat-chief"))
        #expect(ChiefHostStop.isChiefHost(path: "\(bin)/cmux", processName: nil, argv0: "optchat-chief"))
        #expect(!ChiefHostStop.isChiefHost(path: "\(bin)/cmux", processName: nil, argv0: "\(bin)/acpmux"))
        #expect(!ChiefHostStop.isChiefHost(path: "\(bin)/cmux", processName: nil, argv0: "\(bin)/cmux"))
        #expect(!ChiefHostStop.isChiefHost(path: "\(bin)/cmux", processName: nil, argv0: nil))
        // Only the multicall binary is read by argv[0]: another executable started as optchat-chief is not one.
        #expect(!ChiefHostStop.isChiefHost(path: "/usr/bin/python3", processName: nil, argv0: "optchat-chief"))
        // Its bundle replaced (no path): the kernel name is cmux, argv[0] still the link.
        #expect(ChiefHostStop.isChiefHost(path: nil, processName: "cmux", argv0: "\(bin)/optchat-chief"))
        #expect(!ChiefHostStop.isChiefHost(path: nil, processName: "cmux", argv0: "\(bin)/acpmux"))
    }

    @Test func thisProcessHasAName() {
        #expect(ChiefHostStop.processName(getpid())?.isEmpty == false)
    }
}
