import Testing
@testable import CmuxSubrouter

/// Mirrors `sr.go`'s `cookedFromWindows` / `tempCookedFromWindows` cases.
@Suite struct QuotaAssessmentTests {
    private func codexShort(_ percent: Double, reset: Int64 = 3600) -> SubrouterUsageWindow {
        SubrouterUsageWindow(name: "primary", usedPercent: percent, limitWindowSeconds: 5 * 3600, resetAfterSeconds: reset)
    }

    private func codexWeekly(_ percent: Double, reset: Int64 = 86_400) -> SubrouterUsageWindow {
        SubrouterUsageWindow(name: "secondary", usedPercent: percent, limitWindowSeconds: 7 * 24 * 3600, resetAfterSeconds: reset)
    }

    @Test func emptyWindowsAreOK() {
        #expect(SubrouterQuotaAssessment.assess([]) == .ok)
    }

    @Test func healthyWindowsAreOK() {
        #expect(SubrouterQuotaAssessment.assess([codexShort(42), codexWeekly(80)]) == .ok)
    }

    @Test func saturatedWeeklyWindowIsCooked() {
        let weekly = codexWeekly(100)
        #expect(SubrouterQuotaAssessment.assess([codexShort(10), weekly]) == .cooked(weekly))
    }

    @Test func cookedWinsOverTempCooked() {
        // Both windows saturated: the long window's saturation classifies the
        // account as cooked, exactly like longQuotaSaturated in sr.go.
        let weekly = codexWeekly(100)
        #expect(SubrouterQuotaAssessment.assess([codexShort(100), weekly]) == .cooked(weekly))
    }

    @Test func saturatedShortWindowAloneIsTempCooked() {
        let short = codexShort(100)
        #expect(SubrouterQuotaAssessment.assess([short, codexWeekly(55)]) == .tempCooked(short))
    }

    @Test func percentAboveOneHundredIsClamped() {
        let weekly = codexWeekly(140)
        #expect(SubrouterQuotaAssessment.assess([weekly]) == .cooked(weekly))
        #expect(weekly.clampedUsedPercent == 100)
    }

    @Test func negativePercentClampsToZero() {
        #expect(codexShort(-5).clampedUsedPercent == 0)
    }

    @Test func claudeWindowsClassifyByName() {
        // Claude windows carry no LimitWindowSeconds; classification falls
        // back to the names the daemon emits ("5h", "7d", "opus-weekly", …).
        let session = SubrouterUsageWindow(name: "5h", usedPercent: 100, resetAfterSeconds: 900)
        let weekly = SubrouterUsageWindow(name: "7d", usedPercent: 30)
        #expect(session.isShortQuotaWindow)
        #expect(!session.isLongQuotaWindow)
        #expect(weekly.isLongQuotaWindow)
        #expect(SubrouterQuotaAssessment.assess([session, weekly]) == .tempCooked(session))
    }

    @Test func claudeOpusWeeklySaturationIsCooked() {
        let opus = SubrouterUsageWindow(name: "opus-weekly", usedPercent: 100)
        #expect(SubrouterQuotaAssessment.assess([opus]) == .cooked(opus))
    }

    @Test func modelScopedWeeklySaturationDoesNotCookTheAccount() {
        // sr.go's cookedFromWindows skips Feature-scoped windows: draining
        // one model's weekly pool leaves the account usable for the rest.
        let sparkWeekly = SubrouterUsageWindow(
            name: "GPT-5.3-Codex-Spark/secondary",
            usedPercent: 100,
            limitWindowSeconds: 7 * 24 * 3600,
            feature: "GPT-5.3-Codex-Spark"
        )
        #expect(SubrouterQuotaAssessment.assess([sparkWeekly]) == .ok)
        #expect(SubrouterQuotaAssessment.assess([sparkWeekly, codexWeekly(100)])
            == .cooked(codexWeekly(100)))
    }

    @Test func modelScopedShortWindowStillTempCooks() {
        // tempCookedFromWindows applies no model-scope filter, so a
        // feature-scoped short window at 100% still reads temp-cooked.
        let sparkPrimary = SubrouterUsageWindow(
            name: "GPT-5.3-Codex-Spark/primary",
            usedPercent: 100,
            limitWindowSeconds: 5 * 3600,
            resetAfterSeconds: 3600,
            feature: "GPT-5.3-Codex-Spark"
        )
        #expect(SubrouterQuotaAssessment.assess([sparkPrimary]) == .tempCooked(sparkPrimary))
    }

    @Test func firstSaturatedLongWindowWinsInDaemonOrder() {
        let first = SubrouterUsageWindow(name: "7d", usedPercent: 100)
        let second = SubrouterUsageWindow(name: "opus-weekly", usedPercent: 100)
        #expect(SubrouterQuotaAssessment.assess([first, second]) == .cooked(first))
    }

    @Test func nearlyExhaustedThreshold() {
        #expect(codexWeekly(90).isNearlyExhausted)
        #expect(!codexWeekly(89.9).isNearlyExhausted)
    }

    @Test func accountNeedsAttentionForAuthFailure() {
        let account = SubrouterAccountUsageStatus(
            id: "dev@example.com",
            provider: .codex,
            authChecked: true,
            authValid: false
        )
        #expect(account.needsAttention)
    }

    @Test func healthyAccountNeedsNoAttention() {
        let account = SubrouterAccountUsageStatus(
            id: "dev@example.com",
            provider: .codex,
            authChecked: true,
            authValid: true,
            windows: [codexShort(50), codexWeekly(50)]
        )
        #expect(!account.needsAttention)
    }
}
