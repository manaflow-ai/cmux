import Testing

@testable import CmuxMobileWorkspace

@Suite struct MobileOnboardingGateTests {
    @Test func welcomeTruthTable() {
        let cases: [(isAuthenticated: Bool, hasSeenWelcome: Bool, expected: Bool)] = [
            (false, false, true),
            (false, true, false),
            (true, false, false),
            (true, true, false),
        ]

        for testCase in cases {
            let actual = MobileOnboardingGate.shouldShowWelcome(
                isAuthenticated: testCase.isAuthenticated,
                hasSeenWelcome: testCase.hasSeenWelcome
            )
            #expect(actual == testCase.expected)
        }
    }

    @Test func connectTruthTable() {
        let cases: [(
            isAuthenticated: Bool,
            isConnected: Bool,
            hasKnownPairedMac: Bool,
            hasCompletedConnect: Bool,
            expected: Bool
        )] = [
            (false, false, false, false, false),
            (false, false, false, true, false),
            (false, false, true, false, false),
            (false, false, true, true, false),
            (false, true, false, false, false),
            (false, true, false, true, false),
            (false, true, true, false, false),
            (false, true, true, true, false),
            (true, false, false, false, true),
            (true, false, false, true, false),
            (true, false, true, false, false),
            (true, false, true, true, false),
            (true, true, false, false, false),
            (true, true, false, true, false),
            (true, true, true, false, false),
            (true, true, true, true, false),
        ]

        for testCase in cases {
            let actual = MobileOnboardingGate.shouldShowConnect(
                isAuthenticated: testCase.isAuthenticated,
                isConnected: testCase.isConnected,
                hasKnownPairedMac: testCase.hasKnownPairedMac,
                hasCompletedConnect: testCase.hasCompletedConnect
            )
            #expect(actual == testCase.expected)
        }
    }

    @Test func notificationPrimerTruthTable() {
        let cases: [(
            isConnected: Bool,
            hasPrimedNotifications: Bool,
            isPushEnabled: Bool,
            expected: Bool
        )] = [
            (false, false, false, false),
            (false, false, true, false),
            (false, true, false, false),
            (false, true, true, false),
            (true, false, false, true),
            (true, false, true, false),
            (true, true, false, false),
            (true, true, true, false),
        ]

        for testCase in cases {
            let actual = MobileOnboardingGate.shouldPrimeNotifications(
                isConnected: testCase.isConnected,
                hasPrimedNotifications: testCase.hasPrimedNotifications,
                isPushEnabled: testCase.isPushEnabled
            )
            #expect(actual == testCase.expected)
        }
    }
}
