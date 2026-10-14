import CmuxFoundation
import Testing
@testable import CmuxWorkspaces

@Suite("RestorableAgentProcessMatcher")
struct RestorableAgentProcessMatcherTests {
    private let matcher = RestorableAgentProcessMatcher()

    @Test("A reused legacy PID with contradictory process evidence mismatches", arguments: [false, true])
    func reusedLegacyPIDMismatches(hasCurrentIdentity: Bool) {
        let result = matcher.match(.init(
            processID: 42,
            recordedIdentity: nil,
            currentIdentity: hasCurrentIdentity ? identity() : nil,
            presence: .present,
            scopeMatches: true,
            expectedProcessMatches: false
        ))
        #expect(result == .mismatches)
    }

    @Test("A different surface proves a legacy PID is reused even without agent details")
    func reusedLegacyPIDInAnotherScopeMismatches() {
        #expect(matcher.match(.init(
            processID: 42,
            recordedIdentity: nil,
            currentIdentity: nil,
            presence: .present,
            scopeMatches: false,
            expectedProcessMatches: nil
        )) == .mismatches)
    }

    @Test("A matching legacy PID remains unknown without a saved generation", arguments: [false, true])
    func matchingLegacyPIDRemainsUnknown(hasCurrentIdentity: Bool) {
        let result = matcher.match(.init(
            processID: 42,
            recordedIdentity: nil,
            currentIdentity: hasCurrentIdentity ? identity() : nil,
            presence: .present,
            scopeMatches: true,
            expectedProcessMatches: true
        ))
        #expect(result == .unknown)
    }

    @Test("A matching saved process generation authenticates")
    func matchingSavedGenerationAuthenticates() {
        let identity = identity()
        let result = matcher.match(.init(
            processID: 42,
            recordedIdentity: identity,
            currentIdentity: identity,
            presence: .present,
            scopeMatches: true,
            expectedProcessMatches: true
        ))
        #expect(result == .matches)
    }

    @Test("A changed process generation proves PID reuse even when argv is unreadable")
    func changedGenerationMismatches() {
        #expect(matcher.match(.init(
            processID: 42,
            recordedIdentity: identity(),
            currentIdentity: identity(startSeconds: 20),
            presence: .present,
            scopeMatches: nil,
            expectedProcessMatches: nil
        )) == .mismatches)
    }

    @Test("Confirmed absence overrides a previously captured matching process",
          arguments: [false, true])
    func absentProcessOverridesCapturedIdentity(hasRecordedIdentity: Bool) {
        #expect(matcher.match(.init(
            processID: 42,
            recordedIdentity: hasRecordedIdentity ? identity() : nil,
            currentIdentity: identity(),
            presence: .absent,
            scopeMatches: true,
            expectedProcessMatches: true
        )) == .mismatches)
    }

    @Test("Unreadable processes remain uncertain unless their absence is definitive",
          arguments: [RestorableAgentProcessPresence.present, .absent, .unknown], [false, true])
    func unreadableProcessRequiresDefinitiveAbsence(
        presence: RestorableAgentProcessPresence,
        hasRecordedIdentity: Bool
    ) {
        #expect(matcher.match(.init(
            processID: 42,
            recordedIdentity: hasRecordedIdentity ? identity() : nil,
            currentIdentity: nil,
            presence: presence,
            scopeMatches: nil,
            expectedProcessMatches: nil
        )) == (presence == .absent ? .mismatches : .unknown))
    }

    @Test("A saved generation cannot authenticate without a matching current identity")
    func missingCurrentGenerationStaysUnknown() {
        #expect(matcher.match(.init(
            processID: 42,
            recordedIdentity: identity(),
            currentIdentity: nil,
            presence: .present,
            scopeMatches: true,
            expectedProcessMatches: true
        )) == .unknown)
    }

    private func identity(startSeconds: Int64 = 10) -> AgentPIDProcessIdentity {
        AgentPIDProcessIdentity(pid: 42, startSeconds: startSeconds, startMicroseconds: 2)
    }
}
