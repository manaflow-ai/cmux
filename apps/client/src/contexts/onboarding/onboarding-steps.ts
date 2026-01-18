import type { OnboardingStep } from "./onboarding-context";

export const ONBOARDING_STEPS: OnboardingStep[] = [
  {
    id: "welcome",
    title: "Welcome to cmux!",
    description:
      "Let's take a quick tour to help you get started. cmux helps you run multiple AI coding agents in parallel to solve tasks faster.",
    placement: "center",
  },
  {
    id: "dashboard",
    title: "Dashboard",
    description:
      "This is your main workspace. Here you can describe tasks for AI agents to work on. Type your task description in the text area above.",
    targetSelector: "[data-onboarding='dashboard-input']",
    placement: "bottom",
    highlightPadding: 8,
  },
  {
    id: "repo-picker",
    title: "Repository Picker",
    description:
      "Select a GitHub repository or environment for your task. You can connect your GitHub account to access private repos, or paste any public repo URL.",
    targetSelector: "[data-onboarding='repo-picker']",
    placement: "bottom",
    highlightPadding: 4,
  },
  {
    id: "branches",
    title: "Branch Selection",
    description:
      "Choose which branch the agents should start from. They'll create a new branch from here for their changes.",
    targetSelector: "[data-onboarding='branch-picker']",
    placement: "bottom",
    highlightPadding: 4,
  },
  {
    id: "agents",
    title: "Agent Selection",
    description:
      "Pick which AI agents to run. You can select multiple agents to work in parallel - each gets its own isolated workspace. Compare their solutions side by side!",
    targetSelector: "[data-onboarding='agent-picker']",
    placement: "bottom",
    highlightPadding: 4,
  },
  {
    id: "cloud-mode",
    title: "Cloud vs Local Mode",
    description:
      "Toggle between cloud and local execution. Cloud mode runs agents on our servers, while local mode uses Docker on your machine for full control.",
    targetSelector: "[data-onboarding='cloud-toggle']",
    placement: "bottom",
    highlightPadding: 8,
  },
  {
    id: "start-task",
    title: "Start Your Task",
    description:
      "Once you've configured everything, click this button to launch your agents. They'll start working immediately!",
    targetSelector: "[data-onboarding='start-button']",
    placement: "bottom",
    highlightPadding: 4,
  },
  {
    id: "sidebar",
    title: "Navigation Sidebar",
    description:
      "The sidebar shows your recent tasks and provides quick navigation. Click on any task to see its progress, diffs, and agent outputs.",
    targetSelector: "[data-onboarding='sidebar']",
    placement: "right",
    highlightPadding: 0,
  },
  {
    id: "workspaces",
    title: "Workspaces",
    description:
      "View all your tasks in one place. Each task can have multiple agent runs - expand them to see detailed results, code diffs, and terminal outputs.",
    targetSelector: "[data-onboarding='workspaces-link']",
    placement: "right",
    highlightPadding: 4,
  },
  {
    id: "environments",
    title: "Environments",
    description:
      "Pre-configure development environments with custom scripts, packages, and env variables. Environments make your cloud workspaces ready instantly.",
    targetSelector: "[data-onboarding='environments-link']",
    placement: "right",
    highlightPadding: 4,
  },
  {
    id: "settings",
    title: "Settings",
    description:
      "Configure your API keys, theme, and preferences. Add credentials for different AI providers to unlock more agents.",
    targetSelector: "[data-onboarding='settings-link']",
    placement: "right",
    highlightPadding: 4,
  },
  {
    id: "complete",
    title: "You're all set!",
    description:
      "You now know the essentials of cmux. Start by selecting a repository and describing a task. The AI agents will handle the rest!",
    placement: "center",
  },
];
