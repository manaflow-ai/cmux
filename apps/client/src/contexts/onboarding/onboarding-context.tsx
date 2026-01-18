import { createContext, useContext } from "react";

export type OnboardingStepId =
  | "welcome"
  | "dashboard"
  | "repo-picker"
  | "branches"
  | "agents"
  | "cloud-mode"
  | "start-task"
  | "sidebar"
  | "workspaces"
  | "environments"
  | "settings"
  | "complete";

export interface OnboardingStep {
  id: OnboardingStepId;
  title: string;
  description: string;
  targetSelector?: string;
  placement?: "top" | "bottom" | "left" | "right" | "center";
  route?: string;
  highlightPadding?: number;
}

export interface OnboardingContextValue {
  isOnboardingActive: boolean;
  currentStepIndex: number;
  currentStep: OnboardingStep | null;
  steps: OnboardingStep[];
  completedSteps: Set<OnboardingStepId>;
  hasCompletedOnboarding: boolean;
  startOnboarding: () => void;
  nextStep: () => void;
  previousStep: () => void;
  skipOnboarding: () => void;
  completeOnboarding: () => void;
  goToStep: (stepId: OnboardingStepId) => void;
  resetOnboarding: () => void;
}

export const OnboardingContext = createContext<OnboardingContextValue | null>(null);

export function useOnboarding(): OnboardingContextValue {
  const context = useContext(OnboardingContext);
  if (!context) {
    throw new Error("useOnboarding must be used within an OnboardingProvider");
  }
  return context;
}

export function useOnboardingOptional(): OnboardingContextValue | null {
  return useContext(OnboardingContext);
}
