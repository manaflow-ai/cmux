import { useOnboardingOptional } from "@/contexts/onboarding";
import { OnboardingSpotlight } from "./OnboardingSpotlight";
import { OnboardingTooltip } from "./OnboardingTooltip";

export function OnboardingOverlay() {
  const onboarding = useOnboardingOptional();

  if (!onboarding?.isOnboardingActive || !onboarding.currentStep) {
    return null;
  }

  const {
    currentStep,
    currentStepIndex,
    steps,
    nextStep,
    previousStep,
    skipOnboarding,
  } = onboarding;

  const isFirstStep = currentStepIndex === 0;
  const isLastStep = currentStepIndex === steps.length - 1;

  return (
    <>
      <OnboardingSpotlight
        targetSelector={currentStep.targetSelector}
        padding={currentStep.highlightPadding}
        isActive={true}
      />
      <OnboardingTooltip
        step={currentStep}
        currentIndex={currentStepIndex}
        totalSteps={steps.length}
        onNext={nextStep}
        onPrevious={previousStep}
        onSkip={skipOnboarding}
        isFirstStep={isFirstStep}
        isLastStep={isLastStep}
      />
    </>
  );
}
