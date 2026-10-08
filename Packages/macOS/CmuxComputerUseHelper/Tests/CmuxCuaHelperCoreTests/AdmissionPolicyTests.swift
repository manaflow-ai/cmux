// SPDX-License-Identifier: GPL-3.0-or-later
@testable import CmuxCuaHelperCore
import Darwin
import Foundation
import Testing

@Suite struct AdmissionPolicyTests {
    @Test func acpmuxBridgeInsideTheRegisteredTreeIsAdmitted() {
        #expect(AdmissionPolicy.checkIdentity(acpmuxBridge(), config: config()) == nil)
        #expect(AdmissionPolicy.checkSecret(secret, config: config()) == nil)
    }

    /// Required test 1: a valid acpmux signature outside the acpmux tree.
    @Test func validAcpmuxSignatureOutsideTheTreeIsRefused() {
        let shellLaunched = acpmuxBridge(ancestors: [ProcessStamp(pid: 777, startSeconds: 1_700_000_050, startMicroseconds: 0)])
        #expect(AdmissionPolicy.checkIdentity(shellLaunched, config: config()) == .outsideAcpmuxTree)
    }

    /// A second acpmux daemon that a shell started is not the registered one.
    @Test func unregisteredAcpmuxDaemonIsRefused() {
        let rogue = ProcessStamp(pid: 9999, startSeconds: 1_700_000_000, startMicroseconds: 0)
        #expect(AdmissionPolicy.checkIdentity(acpmuxBridge(ancestors: [rogue]), config: config()) == .outsideAcpmuxTree)
    }

    /// A reused daemon pid (same pid, other start time) does not match.
    @Test func reusedDaemonPidIsRefused() {
        let reused = ProcessStamp(pid: daemon.pid, startSeconds: daemon.startSeconds + 60, startMicroseconds: 0)
        #expect(AdmissionPolicy.checkIdentity(acpmuxBridge(ancestors: [reused]), config: config()) == .outsideAcpmuxTree)
    }

    /// Required test 2: a wrong cdhash.
    @Test func wrongCDHashIsRefused() {
        #expect(AdmissionPolicy.checkIdentity(acpmuxBridge(cdhash: otherHash), config: config()) == .unknownCode)
        #expect(AdmissionPolicy.checkIdentity(acpmuxBridge(cdhash: nil), config: config()) == .unknownCode)
    }

    @Test func releaseRequirementAdmitsOnlyWhenConfigured() {
        var peer = acpmuxBridge(cdhash: otherHash)
        peer.satisfiesRequirement = true
        #expect(AdmissionPolicy.checkIdentity(peer, config: config()) == .unknownCode)
        #expect(AdmissionPolicy.checkIdentity(peer, config: config(requirement: "anchor apple generic")) == nil)
    }

    @Test func invalidSignatureAndForeignUserAreRefused() {
        var unsigned = acpmuxBridge()
        unsigned.signatureValid = false
        #expect(AdmissionPolicy.checkIdentity(unsigned, config: config()) == .invalidSignature)
        var foreign = acpmuxBridge()
        foreign.uid = geteuid() &+ 1
        #expect(AdmissionPolicy.checkIdentity(foreign, config: config()) == .foreignUser)
        #expect(AdmissionPolicy.checkIdentity(acpmuxBridge(), config: nil) == .notConfigured)
    }

    /// Required test 3: a missing secret (and a wrong one).
    @Test func missingOrWrongSecretIsRefused() {
        #expect(AdmissionPolicy.checkSecret(nil, config: config()) == .missingSecret)
        #expect(AdmissionPolicy.checkSecret(Data(), config: config()) == .missingSecret)
        #expect(AdmissionPolicy.checkSecret(Data(repeating: 1, count: 32), config: config()) == .wrongSecret)
        #expect(AdmissionPolicy.checkSecret(secret.prefix(16), config: config()) == .wrongSecret)
    }
}
