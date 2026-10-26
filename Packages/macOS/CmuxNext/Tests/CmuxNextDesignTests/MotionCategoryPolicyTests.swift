@testable import CmuxNextDesign
import Testing
import CmuxNextDesignTokens

/// The motion gate's rules (plans/cmux-next/motion-DESIGN.md): an animation runs only when the
/// master switch `ui.animations.enabled` is on, its category's `ui.animations.<category>` is on,
/// the speed is not "off", and Reduce Motion allows it. A category off stops only that category;
/// the master switch off stops every category, whatever their own switches say.
@MainActor @Suite struct MotionCategoryPolicyTests {
    private func base(enabled: Bool = true, disabled: Set<MotionCategory> = [], reduceMotion: Bool = false,
                      speed: MotionSpeed = .fast) -> MotionPolicy {
        MotionPolicy(speed: speed, reduceMotion: reduceMotion, enabledKinds: [.newTab, .newWorkspace],
                     animationsEnabled: enabled, disabledCategories: disabled)
    }

    private func isStill(_ policy: MotionPolicy) -> Bool {
        !policy.animatesMovement && !policy.animatesFades && !policy.animatesLoops
            && policy.duration(MotionFade.fadeIn) == 0 && policy.duration(MotionFade.hover) == 0
            && policy.duration(MotionSpring.move) == 0 && policy.period(.spinner) == nil
            && policy.duration(MotionTween.tabOpen) == 0 && policy.duration(MotionTween.tabMove) == 0
            && policy.marquee(travel: 400) == nil && !policy.animates(.newTab)
    }

    private func isMoving(_ policy: MotionPolicy) -> Bool {
        policy.animatesMovement && policy.animatesFades && policy.animatesLoops
            && policy.duration(MotionFade.fadeIn) > 0 && policy.duration(MotionSpring.move) > 0
            && policy.period(.spinner) != nil && policy.duration(MotionTween.tabMove) > 0
    }

    @Test(arguments: MotionCategory.allCases)
    func oneCategoryOffStopsOnlyThatCategory(_ off: MotionCategory) {
        let policy = base(disabled: [off])
        #expect(isStill(policy.for(off)), "\(off) still animates with its switch off")
        for other in MotionCategory.allCases where other != off {
            #expect(isMoving(policy.for(other)), "\(other) stopped when only \(off) was turned off")
        }
    }

    @Test func theMasterSwitchOverridesEveryCategory() {
        let policy = base(enabled: false)
        for category in MotionCategory.allCases {
            #expect(isStill(policy.for(category)), "\(category) animates with the master switch off")
        }
        #expect(!policy.categoryAnimates, "the category-free policy (reports) animates with the master switch off")
    }

    @Test func turningTheMasterSwitchBackOnRestoresOnlyTheCategoriesThatAreOn() {
        let policy = base(enabled: true, disabled: [.sidebar, .web])
        #expect(isStill(policy.for(.sidebar)))
        #expect(isStill(policy.for(.web)))
        #expect(isMoving(policy.for(.tabs)))
    }

    @Test func everyCategoryAnimatesByDefault() {
        for category in MotionCategory.allCases {
            #expect(isMoving(base().for(category)), "\(category) is off by default")
        }
    }

    @Test(arguments: MotionCategory.allCases)
    func reduceMotionStillAppliesInsideAnOnCategory(_ category: MotionCategory) {
        let policy = base(reduceMotion: true).for(category)
        #expect(!policy.animatesMovement)
        #expect(!policy.animatesLoops)
        #expect(policy.duration(MotionFade.fadeIn) <= MotionFade.crossfade.baseDuration)
        #expect(policy.duration(MotionFade.hover) == 0)
    }

    @Test func speedOffStillStopsEveryCategory() {
        for category in MotionCategory.allCases {
            #expect(isStill(base(speed: .off).for(category)))
        }
    }

    @Test func webPagesGetOffWhenTheirCategoryOrTheMasterSwitchIsOff() {
        #expect(WebTheme.motionValue(base().for(.web)) == "full")
        #expect(WebTheme.motionValue(base(reduceMotion: true).for(.web)) == "reduced")
        #expect(WebTheme.motionValue(base(disabled: [.web]).for(.web)) == "off")
        #expect(WebTheme.motionValue(base(enabled: false).for(.web)) == "off")
        #expect(WebTheme.motionValue(base(disabled: [.tabs]).for(.web)) == "full")
    }

    @Test func everyCategoryHasItsOwnConfigKey() {
        let keys = MotionCategory.allCases.map(\.configKey)
        #expect(Set(keys).count == keys.count)
        // The kind and bounce switches share `ui.animations`; no category may take their keys.
        let taken = Set(MotionKind.allCases.map(\.rawValue) + ["bounce", "enabled"])
        #expect(taken.isDisjoint(with: keys))
    }
}
