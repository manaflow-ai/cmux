import Foundation
import Bonsplit
import Testing
@testable import CmuxWorkspaces

/// Pins the diff arithmetic the four legacy `Workspace` panel-subscription
/// installers ran before writing to bonsplit: a field is recorded only when it
/// differs from the existing tab, `hasCustomTitle` is always carried, the
/// optional-of-optional `icon`/`iconImageData` follow `updateTab` semantics, and
/// an all-unchanged plan is empty (the installer's early-return guard).
@Suite struct SurfaceTabDisplayUpdatePlanTests {
    private func tab(
        title: String = "t",
        icon: String? = nil,
        iconImageData: Data? = nil,
        isDirty: Bool = false,
        isLoading: Bool = false,
        isAudioMuted: Bool = false
    ) -> Bonsplit.Tab {
        Bonsplit.Tab(
            title: title,
            icon: icon,
            iconImageData: iconImageData,
            isDirty: isDirty,
            isLoading: isLoading,
            isAudioMuted: isAudioMuted
        )
    }

    @Test func identicalValuesProduceEmptyPlan() {
        let existing = tab(title: "same", isDirty: true)
        let plan = SurfaceTabDisplayUpdatePlan(
            existing: existing,
            resolvedTitle: "same",
            hasCustomTitle: false,
            isDirty: true
        )
        #expect(plan.isEmpty)
        #expect(plan.title == nil)
        #expect(plan.isDirty == nil)
    }

    @Test func changedTitleAndDirtyAreRecorded() {
        let existing = tab(title: "old", isDirty: false)
        let plan = SurfaceTabDisplayUpdatePlan(
            existing: existing,
            resolvedTitle: "new",
            hasCustomTitle: true,
            isDirty: true
        )
        #expect(!plan.isEmpty)
        #expect(plan.title == "new")
        #expect(plan.isDirty == true)
        #expect(plan.hasCustomTitle == true)
    }

    @Test func unmanagedTitleNeverProposesChange() {
        // The browser installer never passes a nil resolvedTitle, but the
        // contract is: nil resolvedTitle means "do not manage the title".
        let existing = tab(title: "old", isLoading: false)
        let plan = SurfaceTabDisplayUpdatePlan(
            existing: existing,
            resolvedTitle: nil,
            hasCustomTitle: false,
            isLoading: true
        )
        #expect(plan.title == nil)
        #expect(plan.isLoading == true)
        #expect(!plan.isEmpty)
    }

    @Test func browserShapeFaviconLoadingMuted() {
        let favicon = Data([0x01, 0x02])
        let existing = tab(title: "T", isLoading: false, isAudioMuted: false)
        let plan = SurfaceTabDisplayUpdatePlan(
            existing: existing,
            resolvedTitle: "T",
            hasCustomTitle: false,
            iconImageData: .some(favicon),
            isLoading: true,
            isAudioMuted: true
        )
        #expect(plan.title == nil) // unchanged
        #expect(plan.iconImageData == .some(.some(favicon)))
        #expect(plan.isLoading == true)
        #expect(plan.isAudioMuted == true)
    }

    @Test func faviconUnchangedIsNotRecorded() {
        let favicon = Data([0x01, 0x02])
        let existing = tab(title: "T", iconImageData: favicon)
        let plan = SurfaceTabDisplayUpdatePlan(
            existing: existing,
            resolvedTitle: "T",
            hasCustomTitle: false,
            iconImageData: .some(favicon),
            isLoading: false,
            isAudioMuted: false
        )
        #expect(plan.iconImageData == nil)
        #expect(plan.isEmpty)
    }

    @Test func filePreviewIconChangeRecorded() {
        let existing = tab(title: "T", icon: "doc")
        let plan = SurfaceTabDisplayUpdatePlan(
            existing: existing,
            resolvedTitle: "T",
            hasCustomTitle: false,
            icon: .some("doc.fill"),
            isDirty: false
        )
        #expect(plan.icon == .some(.some("doc.fill")))
        #expect(!plan.isEmpty)
    }

    @Test func clearingIconToNilIsRecordedWhenExistingHadIcon() {
        let existing = tab(title: "T", icon: "doc")
        let plan = SurfaceTabDisplayUpdatePlan(
            existing: existing,
            resolvedTitle: "T",
            hasCustomTitle: false,
            icon: .some(nil),
            isDirty: false
        )
        #expect(plan.icon == .some(.none))
        #expect(!plan.isEmpty)
    }

    @MainActor
    @Test func applyWritesDeltasToController() {
        let controller = BonsplitController()
        guard let tabId = controller.createTab(title: "old", icon: nil, isDirty: false),
              let existing = controller.tab(tabId) else {
            Issue.record("expected a tab on a fresh controller")
            return
        }
        let plan = SurfaceTabDisplayUpdatePlan(
            existing: existing,
            resolvedTitle: "new",
            hasCustomTitle: true,
            isDirty: true
        )
        plan.apply(to: controller, tabId: tabId)
        let updated = controller.tab(tabId)
        #expect(updated?.title == "new")
        #expect(updated?.isDirty == true)
        #expect(updated?.hasCustomTitle == true)
    }

    @MainActor
    @Test func applyEmptyPlanIsNoOp() {
        let plan = SurfaceTabDisplayUpdatePlan(hasCustomTitle: false)
        #expect(plan.isEmpty)
        // apply on an empty plan with a controller that has no such tab must not
        // crash; the guard returns before touching the controller.
        plan.apply(to: BonsplitController(), tabId: TabID())
    }
}
