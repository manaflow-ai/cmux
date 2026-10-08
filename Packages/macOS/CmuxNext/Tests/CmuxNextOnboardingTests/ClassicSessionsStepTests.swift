import Foundation
import Testing
@testable import CmuxNextOnboarding

@MainActor
@Suite struct ClassicSessionsStepTests {
    private enum ScanFailure: Error { case corrupt }

    private func settle(_ model: ClassicSessionsStepModel) async {
        for _ in 0..<200 where !model.scanned { await Task.yield() }
    }

    @Test func continueBackContinueImportsEachWorkspaceOnce() async {
        let services = MockOnboardingServices()
        services.classicWorkspaces = [
            ClassicSessionWorkspace(name: "cmux", workingDirectory: "/work/cmux", layout: .pane(ClassicSessionPane(tabs: [])))
        ]
        let model = ClassicSessionsStepModel(services: services)
        model.scan()
        await settle(model)

        model.commit()
        model.commit()

        #expect(services.importedClassicSessions == [services.classicWorkspaces])
    }

    @Test func scanFailureStaysVisibleToTheUser() async {
        let services = MockOnboardingServices()
        services.canImportClassicSessions = true
        services.classicSessionsError = ScanFailure.corrupt
        let model = OnboardingModel(services: services, start: .classicSessions)
        model.stepDidAppear()
        for _ in 0..<200 where model.classicSessions.scanError == nil { await Task.yield() }

        #expect(model.classicSessions.scanned)
        #expect(model.classicSessions.workspaces.isEmpty)
        #expect(model.classicSessions.scanError != nil)
        #expect(model.steps.contains(.classicSessions))
    }
}
