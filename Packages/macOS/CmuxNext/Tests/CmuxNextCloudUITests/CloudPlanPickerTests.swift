import AppKit
import CmuxNextCloudUI
import CmuxNextDesign
import Foundation
import Testing

/// The Cloud plan picker (cmux#38299): Monthly first, Annual bills Pro and Max yearly at their saving while Team
/// stays monthly, each card says what is due today, and the picker shown over a window answers the person's pick
/// once (a plan, Run on This Mac, or nil for Not Now, Escape or the window closing).
@MainActor @Suite(.serialized) struct CloudPlanPickerTests {
    private func plan(_ id: CloudPlanPicker.PlanID) throws -> CloudPlanPicker.Plan { try #require(CloudPlanPicker.plans.first { $0.id == id }) }

    @Test func monthlyIsTheDefaultAndShowsPricesAndDueToday() throws {
        let picker = CloudPlanPicker()
        #expect(picker.interval == .month)
        #expect(CloudPlanPicker.plans.map(\.id) == [.pro, .max, .team])
        #expect(CloudPlanPicker.plans.map { picker.monthlyPrice($0) } == [50, 200, 60])
        #expect(CloudPlanPicker.plans.map { picker.dueToday($0) } == [50, 200, 60])
        #expect(picker.choice(try plan(.max)) == .plan(.max, .month))
    }

    @Test func annualBillsProAndMaxYearlyAndKeepsTeamMonthly() throws {
        let picker = CloudPlanPicker(interval: .year)
        #expect(picker.monthlyPrice(try plan(.pro)) == 40 && picker.dueToday(try plan(.pro)) == 480)
        #expect(picker.monthlyPrice(try plan(.max)) == 160 && picker.dueToday(try plan(.max)) == 1_920)
        #expect(picker.monthlyPrice(try plan(.team)) == 60 && picker.dueToday(try plan(.team)) == 60)
        #expect(picker.choice(try plan(.pro)) == .plan(.pro, .year))
        #expect(picker.choice(try plan(.team)) == .plan(.team, .month), "Team is sold monthly only")
        #expect(CloudPlanPicker.annualSaving(try plan(.pro)) == 20 && CloudPlanPicker.annualSaving(try plan(.team)) == nil)
        #expect(CloudPlanPicker.bestAnnualSaving == 20)
    }

    @Test func theRefusalsPlanIsRecommended() {
        #expect(CloudPlanPicker.recommended(for: "max") == .max)
        #expect(CloudPlanPicker.recommended(for: "pro") == .pro)
        #expect(CloudPlanPicker.recommended(for: nil) == .pro)
        #expect(CloudPlanPicker().shownPlans.map(\.id) == [.pro, .max, .team])
        // A refusal that needs Max comes from an account that already pays: it is offered Max only, not Pro again.
        #expect(CloudPlanPicker(recommended: .max).shownPlans.map(\.id) == [.max])
    }

    @Test func pricesAreWholeDollars() {
        #expect(CloudPlanPicker.price(1_920, locale: Locale(identifier: "en_US")) == "$1,920")
    }

    private func window() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 760), styleMask: [.titled, .resizable], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        return window
    }

    /// Waits for the presenter to put its view on the window (it presents in the call's first turn).
    private func shown(in window: NSWindow) async -> CloudPlanPickerHostingView? {
        for _ in 0..<100 {
            if let view = CloudPlanPickerPresenter().shown(in: window) { return view }
            await Task.yield()
        }
        return nil
    }

    @Test func thePickerFillsTheWindowAndAnswersThePickedPlanOnce() async throws {
        let window = window()
        defer { window.close() }
        let answer = Task { await CloudPlanPickerPresenter().choose(CloudPlanPicker(interval: .year, offersRunHere: true), in: window) }
        let view = try #require(await shown(in: window))
        #expect(view.frame.size == window.contentView?.bounds.size, "the picker fills the window")
        #expect(view.accessibilityRole() == .group && view.isAccessibilityModal())
        view.choose(.plan(.max, .year))
        view.notNow()
        #expect(await answer.value == .plan(.max, .year), "the first pick is the answer")
        #expect(await CloudPlanPickerPresenter().choose(CloudPlanPicker(), in: nil) == nil, "no window: no picker")
    }

    @Test func notNowAndEscapeAnswerNothing() async throws {
        let window = window()
        defer { window.close() }
        let dismissed = Task { await CloudPlanPickerPresenter().choose(CloudPlanPicker(), in: window) }
        try #require(await shown(in: window)).notNow()
        #expect(await dismissed.value == nil)

        let escaped = Task { await CloudPlanPickerPresenter().choose(CloudPlanPicker(), in: window) }
        try #require(await shown(in: window)).cancelOperation(nil)
        #expect(await escaped.value == nil)
    }

    @Test func runOnThisMacIsTheFreeWayOut() async throws {
        let window = window()
        defer { window.close() }
        let answer = Task { await CloudPlanPickerPresenter().choose(CloudPlanPicker(offersRunHere: true), in: window) }
        try #require(await shown(in: window)).choose(.runHere)
        #expect(await answer.value == .runHere)
    }
}
