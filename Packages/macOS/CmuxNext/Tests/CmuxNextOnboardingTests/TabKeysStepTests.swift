import AppKit
import Foundation
import Testing
@testable import CmuxNextOnboarding

/// D4 (cx-aha.1): the first run asks what Ctrl-1…9 select, tabs (the
/// default) or Spaces. Continue writes a changed pick; Skip and closing
/// the window write nothing.
@MainActor
@Suite struct TabKeysStepTests {
    func services(current: TabKeysChoice? = .tabs) -> MockOnboardingServices {
        let services = MockOnboardingServices()
        services.accountsView = NSView()
        services.offersTabKeys = true
        services.tabKeys = current
        return services
    }

    func loaded(_ model: OnboardingModel) async {
        model.stepDidAppear()
        for _ in 0..<200 where !model.tabKeys.isLoaded { await Task.yield() }
    }

    @Test func theFirstRunAsksAfterTheSignIns() {
        let model = OnboardingModel(services: services())
        #expect(model.steps.prefix(2) == [.accounts, .tabKeys])
        #expect(model.steps.last == .importData)
    }

    @Test func notOfferedLeavesTheFirstRunAsItWas() {
        let services = services()
        services.offersTabKeys = false
        #expect(!OnboardingModel(services: services).steps.contains(.tabKeys))
    }

    @Test func theStepShowsWhatCmuxJsonIsOn() async {
        let model = OnboardingModel(services: services(current: .spaces), start: .tabKeys)
        #expect(model.step == .tabKeys)
        await loaded(model)
        #expect(model.tabKeys.selected == .spaces)
        #expect(model.tabKeys.current == .spaces)
    }

    @Test func continueWritesAChangedPick() async {
        let services = services()
        let model = OnboardingModel(services: services, start: .tabKeys)
        await loaded(model)
        model.tabKeys.select(.spaces)
        model.next()
        #expect(services.appliedTabKeys == [.spaces])
        #expect(model.step != .tabKeys)
    }

    @Test func continueOnTheCurrentChoiceWritesNothing() async {
        let services = services(current: .tabs)
        let model = OnboardingModel(services: services, start: .tabKeys)
        await loaded(model)
        model.next()
        #expect(services.appliedTabKeys.isEmpty)
    }

    @Test func skipAndCloseWriteNothing() async {
        let services = services()
        let model = OnboardingModel(services: services, start: .tabKeys)
        await loaded(model)
        model.tabKeys.select(.spaces)
        model.skipStep()
        #expect(services.appliedTabKeys.isEmpty)
        let closed = OnboardingModel(services: services, start: .tabKeys)
        await loaded(closed)
        closed.tabKeys.select(.spaces)
        closed.leave()
        #expect(services.appliedTabKeys.isEmpty)
    }

    /// Keys bound by hand: no radio is on, and Continue without a pick
    /// writes nothing; a pick still writes (the App keeps hand bindings).
    @Test func keysBoundByHandShowNoChoice() async {
        let services = services(current: nil)
        let model = OnboardingModel(services: services, start: .tabKeys)
        await loaded(model)
        #expect(model.tabKeys.selected == nil)
        model.next()
        #expect(services.appliedTabKeys.isEmpty)
        let picked = OnboardingModel(services: services, start: .tabKeys)
        await loaded(picked)
        picked.tabKeys.select(.tabs)
        picked.next()
        #expect(services.appliedTabKeys == [.tabs])
    }
}
