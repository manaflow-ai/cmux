import CoreGraphics
import Foundation
import Testing
@testable import CmuxMobileTerminalKit

@Suite("Terminal dock keyboard transition planning")
struct TerminalDockKeyboardTransitionPlannerTests {
    private let planner = TerminalDockKeyboardTransitionPlanner()

    @Test("settled dock ignores a notification for its visible occupancy")
    func settledDockIgnoresMatchingTarget() {
        let plan = planner.plan(for: input(
            targetOverlap: 336,
            visibleOccupancy: 336,
            targetOccupancy: 336
        ))

        #expect(plan == .ignore)
    }

    @Test("mid-flight notification for the same destination is ignored")
    func midFlightSameDestinationIsIgnored() {
        let plan = planner.plan(for: input(
            targetOverlap: 336,
            visibleOccupancy: 180,
            targetOccupancy: 336,
            isAnimating: true,
            activeTargetOverlap: 336
        ))

        #expect(plan == .ignore)
    }

    @Test("mid-flight fresh destination animates from a stale visible position")
    func midFlightDifferentDestinationAnimates() {
        let plan = planner.plan(for: input(
            targetOverlap: 0,
            notificationDuration: 0.3,
            visibleOccupancy: 220,
            targetOccupancy: 34,
            isAnimating: true,
            activeTargetOverlap: 336
        ))

        #expect(plan == .animate(duration: 0.3))
    }

    @Test("zero-duration interruption synthesizes a remaining-fraction duration")
    func zeroDurationSynthesizesDuration() {
        let plan = planner.plan(for: input(
            targetOverlap: 0,
            notificationDuration: 0,
            visibleOccupancy: 220,
            targetOccupancy: 34,
            isAnimating: true,
            activeTargetOverlap: 336,
            lastTransitionDuration: 0.25
        ))
        guard case let .animate(duration) = plan else {
            Issue.record("Expected a synthesized animation")
            return
        }

        #expect(duration == 0.25 * (186.0 / 336.0))
    }

    @Test("tiny remaining distance applies directly when an old animation is active")
    func tinyDistanceAppliesDirectly() {
        let plan = planner.plan(for: input(
            targetOverlap: 200,
            visibleOccupancy: 199.75,
            targetOccupancy: 200,
            isAnimating: true,
            activeTargetOverlap: 336
        ))

        #expect(plan == .apply)
    }

    @Test("visible occupancy converts around the safe-area boundary")
    func pinnedOverlapConversions() {
        #expect(planner.pinnedOverlap(
            forVisibleOccupancy: 34,
            bottomSafeAreaInset: 34
        ) == 0)
        #expect(planner.pinnedOverlap(
            forVisibleOccupancy: 34.5,
            bottomSafeAreaInset: 34
        ) == 0)
        #expect(planner.pinnedOverlap(
            forVisibleOccupancy: 34.51,
            bottomSafeAreaInset: 34
        ) == 34.51)
        #expect(planner.pinnedOverlap(
            forVisibleOccupancy: 0,
            bottomSafeAreaInset: 0
        ) == 0)
        #expect(planner.pinnedOverlap(
            forVisibleOccupancy: 0.51,
            bottomSafeAreaInset: 0
        ) == 0.51)
    }

    private func input(
        targetOverlap: CGFloat,
        notificationDuration: TimeInterval = 0.25,
        visibleOccupancy: CGFloat,
        targetOccupancy: CGFloat,
        isAnimating: Bool = false,
        activeTargetOverlap: CGFloat = 0,
        lastTransitionDuration: TimeInterval = 0.25
    ) -> TerminalDockKeyboardTransitionInput {
        TerminalDockKeyboardTransitionInput(
            targetOverlap: targetOverlap,
            notificationDuration: notificationDuration,
            visibleOccupancy: visibleOccupancy,
            targetOccupancy: targetOccupancy,
            isAnimating: isAnimating,
            activeTargetOverlap: activeTargetOverlap,
            lastTransitionDuration: lastTransitionDuration
        )
    }
}
