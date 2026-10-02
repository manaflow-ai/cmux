import Foundation
import Testing
@testable import CmuxNextOnboarding

/// The role step ("Which best describes your work?"): one answer, saved on
/// Continue, kept in the state file across the end of onboarding.
@MainActor
@Suite struct RoleStepTests {
    @Test func roleIsTheFirstStepAndContinueSavesTheAnswer() {
        let services = MockOnboardingServices()
        let model = OnboardingModel(services: services)
        #expect(model.step == .role)
        model.role.select(.engineering)
        model.role.suggestTasks = true
        model.next()
        #expect(model.step == .defaultBrowser)
        #expect(services.savedProfile == OnboardingProfile(role: .engineering, suggestTasks: true))
    }

    @Test func aDescriptionAndARoleReplaceEachOther() {
        let model = OnboardingModel(services: MockOnboardingServices())
        model.role.select(.design)
        model.role.describe("  Robotics research ")
        #expect(model.role.role == nil)
        #expect(model.role.profile == OnboardingProfile(otherRole: "Robotics research"))
        model.role.select(.legal)
        #expect(model.role.otherRole.isEmpty && model.role.profile.role == .legal)
        // Spaces alone are not a description: the role stays.
        model.role.describe("   ")
        #expect(model.role.role == .legal)
    }

    @Test func skipOrContinueWithoutAnAnswerSavesNothing() {
        let skipping = MockOnboardingServices()
        let model = OnboardingModel(services: skipping)
        model.role.select(.sales)
        model.skipStep()
        #expect(skipping.savedProfile == nil && model.step == .defaultBrowser)

        let empty = MockOnboardingServices()
        let blank = OnboardingModel(services: empty)
        blank.next()
        #expect(empty.savedProfile == nil && blank.step == .defaultBrowser)
    }

    /// "Onboarding…" opens the step with the earlier answer.
    @Test func reopeningStartsFromTheSavedAnswer() {
        let services = MockOnboardingServices()
        services.savedProfile = OnboardingProfile(otherRole: "Teaching", suggestTasks: true)
        let model = OnboardingModel(services: services)
        #expect(model.role.role == nil && model.role.otherRole == "Teaching" && model.role.suggestTasks)
    }

    @Test func everyRoleHasItsOwnLabel() {
        let labels = OnboardingRole.allCases.map(OnboardingStrings.roleName)
        #expect(!labels.contains(where: \.isEmpty))
        #expect(Set(labels).count == labels.count)
    }
}

/// The state file keeps the answer without marking onboarding done early.
@Suite struct OnboardingProfileFileTests {
    func file() -> (OnboardingStateFile, URL) {
        let url = FileManager.default.temporaryDirectory.appending(path: "onboarding-\(UUID().uuidString)/onboarding.json")
        return (OnboardingStateFile(url: url), url)
    }

    @Test func anAnswerSavedMidwayStillShowsOnboardingAndSurvivesTheEnd() throws {
        let (state, url) = file()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let answer = OnboardingProfile(role: .student, suggestTasks: false)
        try state.saveProfile(answer)
        #expect(state.needsOnboarding(), "saving the answer is not finishing onboarding")
        #expect(state.profile() == answer)
        try state.markDone(completed: true)
        #expect(!state.needsOnboarding())
        #expect(state.profile() == answer)
        let newer = OnboardingProfile(role: .finance)
        try state.markDone(completed: true, profile: newer)
        #expect(state.profile() == newer)
    }

    @Test func aFileFromBeforeTheRoleStepStillReads() throws {
        let (state, url) = file()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"version":1,"completed":true,"date":0}"#.utf8).write(to: url)
        #expect(!state.needsOnboarding())
        #expect(state.profile() == nil)
        try state.saveProfile(OnboardingProfile(role: .product))
        #expect(!state.needsOnboarding(), "an answer from Onboarding… keeps the finished record")
    }
}
