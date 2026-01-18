import { useCallback, useEffect, useMemo, useState, type ReactNode } from "react";
import {
  OnboardingContext,
  type OnboardingContextValue,
  type OnboardingStepId,
} from "./onboarding-context";
import { ONBOARDING_STEPS } from "./onboarding-steps";

const STORAGE_KEY = "cmux-onboarding";

interface StoredOnboardingState {
  completed: boolean;
  completedSteps: OnboardingStepId[];
  skipped: boolean;
}

function loadStoredState(): StoredOnboardingState {
  try {
    const stored = localStorage.getItem(STORAGE_KEY);
    if (stored) {
      const parsed = JSON.parse(stored) as StoredOnboardingState;
      return {
        completed: parsed.completed ?? false,
        completedSteps: parsed.completedSteps ?? [],
        skipped: parsed.skipped ?? false,
      };
    }
  } catch (err) {
    console.error("Failed to load onboarding state:", err);
  }
  return { completed: false, completedSteps: [], skipped: false };
}

function saveStoredState(state: StoredOnboardingState): void {
  try {
    localStorage.setItem(STORAGE_KEY, JSON.stringify(state));
  } catch (err) {
    console.error("Failed to save onboarding state:", err);
  }
}

interface OnboardingProviderProps {
  children: ReactNode;
}

export function OnboardingProvider({ children }: OnboardingProviderProps) {
  const [isOnboardingActive, setIsOnboardingActive] = useState(false);
  const [currentStepIndex, setCurrentStepIndex] = useState(0);
  const [completedSteps, setCompletedSteps] = useState<Set<OnboardingStepId>>(
    () => new Set(loadStoredState().completedSteps)
  );
  const [hasCompletedOnboarding, setHasCompletedOnboarding] = useState(
    () => loadStoredState().completed || loadStoredState().skipped
  );

  // Auto-start onboarding for new users
  useEffect(() => {
    const stored = loadStoredState();
    if (!stored.completed && !stored.skipped) {
      // Small delay to let the UI render first
      const timer = setTimeout(() => {
        setIsOnboardingActive(true);
      }, 500);
      return () => clearTimeout(timer);
    }
  }, []);

  const currentStep = useMemo(() => {
    if (!isOnboardingActive) return null;
    return ONBOARDING_STEPS[currentStepIndex] ?? null;
  }, [isOnboardingActive, currentStepIndex]);

  const startOnboarding = useCallback(() => {
    setCurrentStepIndex(0);
    setIsOnboardingActive(true);
  }, []);

  const nextStep = useCallback(() => {
    const currentId = ONBOARDING_STEPS[currentStepIndex]?.id;
    if (currentId) {
      setCompletedSteps((prev) => {
        const next = new Set(prev);
        next.add(currentId);
        return next;
      });
    }

    if (currentStepIndex < ONBOARDING_STEPS.length - 1) {
      setCurrentStepIndex((prev) => prev + 1);
    } else {
      // Last step - complete the onboarding
      setIsOnboardingActive(false);
      setHasCompletedOnboarding(true);
      const allStepIds = ONBOARDING_STEPS.map((s) => s.id);
      saveStoredState({
        completed: true,
        completedSteps: allStepIds,
        skipped: false,
      });
    }
  }, [currentStepIndex]);

  const previousStep = useCallback(() => {
    if (currentStepIndex > 0) {
      setCurrentStepIndex((prev) => prev - 1);
    }
  }, [currentStepIndex]);

  const skipOnboarding = useCallback(() => {
    setIsOnboardingActive(false);
    setHasCompletedOnboarding(true);
    saveStoredState({
      completed: false,
      completedSteps: Array.from(completedSteps),
      skipped: true,
    });
  }, [completedSteps]);

  const completeOnboarding = useCallback(() => {
    setIsOnboardingActive(false);
    setHasCompletedOnboarding(true);
    const allStepIds = ONBOARDING_STEPS.map((s) => s.id);
    saveStoredState({
      completed: true,
      completedSteps: allStepIds,
      skipped: false,
    });
  }, []);

  const goToStep = useCallback((stepId: OnboardingStepId) => {
    const index = ONBOARDING_STEPS.findIndex((s) => s.id === stepId);
    if (index >= 0) {
      setCurrentStepIndex(index);
      setIsOnboardingActive(true);
    }
  }, []);

  const resetOnboarding = useCallback(() => {
    setCompletedSteps(new Set());
    setHasCompletedOnboarding(false);
    setCurrentStepIndex(0);
    setIsOnboardingActive(false);
    saveStoredState({ completed: false, completedSteps: [], skipped: false });
  }, []);

  // Save completed steps when they change
  useEffect(() => {
    if (completedSteps.size > 0 && !hasCompletedOnboarding) {
      const stored = loadStoredState();
      saveStoredState({
        ...stored,
        completedSteps: Array.from(completedSteps),
      });
    }
  }, [completedSteps, hasCompletedOnboarding]);

  // Cmd+K to restart onboarding (debug shortcut)
  useEffect(() => {
    function handleKeyDown(e: KeyboardEvent) {
      if ((e.metaKey || e.ctrlKey) && e.key === "k") {
        e.preventDefault();
        // Reset and restart onboarding
        setCompletedSteps(new Set());
        setHasCompletedOnboarding(false);
        setCurrentStepIndex(0);
        saveStoredState({ completed: false, completedSteps: [], skipped: false });
        setIsOnboardingActive(true);
      }
    }
    window.addEventListener("keydown", handleKeyDown);
    return () => window.removeEventListener("keydown", handleKeyDown);
  }, []);

  const contextValue: OnboardingContextValue = useMemo(
    () => ({
      isOnboardingActive,
      currentStepIndex,
      currentStep,
      steps: ONBOARDING_STEPS,
      completedSteps,
      hasCompletedOnboarding,
      startOnboarding,
      nextStep,
      previousStep,
      skipOnboarding,
      completeOnboarding,
      goToStep,
      resetOnboarding,
    }),
    [
      isOnboardingActive,
      currentStepIndex,
      currentStep,
      completedSteps,
      hasCompletedOnboarding,
      startOnboarding,
      nextStep,
      previousStep,
      skipOnboarding,
      completeOnboarding,
      goToStep,
      resetOnboarding,
    ]
  );

  return (
    <OnboardingContext.Provider value={contextValue}>
      {children}
    </OnboardingContext.Provider>
  );
}
