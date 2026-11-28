#if canImport(CmuxMobileLinkFFI)
import CmuxMobileAgentChat
import CmuxMobileTransport
import Foundation
import Testing
@testable import CmuxMobileLive

/// The phone's acpmux ABI range on its link to the Mac (hq RFD 0224, phase 2): it names its range
/// in `initialize`, serves any Mac that shares a revision or names none, and turns a range the two
/// do not share, from either side, into one non-transient link error naming what to update.
@Suite struct AcpmuxHubLinkABITests {
    static func json(_ text: String) -> JSONValue {
        try! JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
    }

    @Test func initializeNamesTheRange() {
        let meta = AcpmuxHub.initializeABIMeta
        let abi = meta["abi"]?.numberValue ?? -1
        let abiMin = meta["abiMin"]?.numberValue ?? -1
        #expect(abi >= 2)
        #expect(abiMin >= 0 && abiMin < abi)
    }

    @Test func aMacThatSharesARevisionOrNamesNoneIsServed() {
        #expect(AcpmuxHub.abiIncompatible(initialized: Self.json(#"{"_meta":{"acpmux":{"version":"0.1"}}}"#)) == nil)
        #expect(AcpmuxHub.abiIncompatible(initialized: Self.json(#"{"_meta":{"acpmux":{"abi":2,"abiMin":0}}}"#)) == nil)
        #expect(AcpmuxHub.abiIncompatible(initialized: Self.json(#"{"_meta":{"acpmux":{"abi":3,"abiMin":2}}}"#)) == nil)
    }

    @Test func aNewerMacThatDroppedOursNamesTheApp() throws {
        let error = try #require(AcpmuxHub.abiIncompatible(initialized: Self.json(#"{"_meta":{"acpmux":{"abi":9,"abiMin":8}}}"#)))
        #expect(error.code == AcpmuxHub.versionIncompatible)
        #expect(!error.isTransient)
        #expect(error.displayReason.hasPrefix("Update the cmux app"))
    }

    @Test func theMacsRefusalNamesTheSide() throws {
        let peer = AcpmuxConnection.RPCError(code: -32600, message: "no revision in common", reason: nil,
                                             errorKind: "version.incompatible", update: "peer")
        #expect(try #require(AcpmuxHub.abiIncompatible(refusal: peer)).displayReason.hasPrefix("Update the cmux app"))
        let own = AcpmuxConnection.RPCError(code: -32600, message: "no revision in common", reason: nil,
                                            errorKind: "version.incompatible", update: "self")
        #expect(try #require(AcpmuxHub.abiIncompatible(refusal: own)).displayReason.hasPrefix("Update cmux on your Mac"))
        let other = AcpmuxConnection.RPCError(code: -32600, message: "busy", reason: nil)
        #expect(AcpmuxHub.abiIncompatible(refusal: other) == nil)
    }
}
#endif
