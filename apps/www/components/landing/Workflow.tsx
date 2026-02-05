"use client";

import { useState } from "react";
import FakeCmuxUI, { type FakeCmuxUIVariant } from "./FakeCmuxUI";

const steps: {
  number: number;
  title: string;
  subtitle: string;
  bullets: string[];
  browserTitle: string;
  variant: FakeCmuxUIVariant;
}[] = [
  {
    number: 1,
    title: "Pick a repo and start agents",
    subtitle: "Connect your GitHub repo, choose which agents to run, and kick off the task.",
    bullets: [
      "Link your repo or set up a fresh environment with your dev scripts.",
      "Pick the branch you want agents to work on.",
      "Select Claude Code, Codex, Gemini—whatever agents you want racing on this task.",
    ],
    browserTitle: "cmux — Start a Run",
    variant: "dashboard",
  },
  {
    number: 2,
    title: "Watch them work",
    subtitle: "Each agent gets its own VS Code. Click into any session to see what it's doing.",
    bullets: [
      "See live progress in each agent's dedicated editor.",
      "Green checkmark means done—wait for all agents to finish.",
      "cmux picks a recommended winner, but you make the final call.",
    ],
    browserTitle: "cmux — Agents Working",
    variant: "tasks",
  },
  {
    number: 3,
    title: "Compare the results",
    subtitle: "Review what each agent built. Check the diffs, run the tests, preview the app.",
    bullets: [
      "Side-by-side diff view shows exactly what changed.",
      "See test output and any errors that came up.",
      "Click the preview URL to test the actual running app.",
    ],
    browserTitle: "cmux — Review Changes",
    variant: "diff",
  },
  {
    number: 4,
    title: "Merge and ship",
    subtitle: "Happy with one? Create a PR and merge it—all without leaving cmux.",
    bullets: [
      "One click to open a pull request from the best solution.",
      "Add notes, check that CI passes.",
      "Merge when you're ready. Done.",
    ],
    browserTitle: "cmux — Create PR",
    variant: "pr",
  },
];

function WorkflowPreview({ variant }: { variant: FakeCmuxUIVariant }) {
  const scale = 0.5;
  const frameWidth = 1152;
  const frameHeight = 600;
  return (
    <div className="relative w-full h-[300px] overflow-hidden bg-neutral-100 dark:bg-neutral-900 rounded-lg border border-neutral-200 dark:border-neutral-800">
      <div
        className="origin-top-left"
        style={{
          transform: `scale(${scale})`,
          width: `${frameWidth}px`,
          height: `${frameHeight}px`,
        }}
      >
        <FakeCmuxUI
          variant={variant}
          draggable={false}
          showDragHint={false}
          className="pointer-events-none"
        />
      </div>
    </div>
  );
}

export default function Workflow() {
  const [activeStep, setActiveStep] = useState(0);

  return (
    <section className="py-32 relative bg-neutral-100/80 dark:bg-black/80">
      <div className="relative z-10 max-w-7xl mx-auto px-6">
        {/* Section header */}
        <div className="text-left mb-6">
          <h2 className="text-3xl md:text-5xl mb-6 leading-tight text-neutral-900 dark:text-white tracking-tighter" style={{ fontWeight: 420 }}>
            How it <span className="text-[#3B82F6]">works.</span>
          </h2>
          <p className="text-lg text-neutral-600 dark:text-neutral-400 max-w-3xl">
            Start a task, let agents compete, pick the best code, ship it. Four steps.
          </p>
        </div>

        {/* Workflow steps */}
        <div className="mt-16 grid lg:grid-cols-2 gap-12 items-start">
          {/* Left: Steps list */}
          <div className="space-y-4">
            {steps.map((step, index) => (
              <div
                key={step.number}
                className={`cursor-pointer transition-all duration-500 flex gap-4 ${
                  activeStep === index
                    ? "opacity-100"
                    : "opacity-50 hover:opacity-70"
                }`}
                onClick={() => setActiveStep(index)}
              >
                {/* Thin chevron indicator */}
                <div className="flex-shrink-0 pt-1">
                  <svg
                    width="8"
                    height="20"
                    viewBox="0 0 12 20"
                    className={`transition-colors duration-300 ${
                      activeStep === index ? "text-neutral-400" : "text-neutral-600"
                    }`}
                  >
                    <polygon
                      points="0,0 8,10 0,20 1.5,20 9.5,10 1.5,0"
                      fill="currentColor"
                    />
                  </svg>
                </div>
                <div className="flex-1">
                  <h3 className={`font-medium mb-1 transition-all duration-300 ${
                    activeStep === index ? "text-xl text-neutral-900 dark:text-white" : "text-base text-neutral-600 dark:text-neutral-300"
                  }`}>
                    {step.title}
                  </h3>
                  <div className={`overflow-hidden transition-all duration-500 ${
                    activeStep === index ? "max-h-96 opacity-100" : "max-h-0 opacity-0"
                  }`}>
                    <p className="text-sm text-neutral-600 dark:text-neutral-400 mb-4 mt-2">
                      {step.subtitle}
                    </p>
                    <ul className="space-y-2">
                      {step.bullets.map((bullet, i) => (
                        <li key={i} className="flex items-start gap-2 text-sm text-neutral-600 dark:text-neutral-400">
                          <span className="text-neutral-400 dark:text-neutral-500 mt-0.5">•</span>
                          {bullet}
                        </li>
                      ))}
                    </ul>
                  </div>
                </div>
              </div>
            ))}
          </div>

          {/* Right: Preview */}
          <div className="lg:sticky lg:top-32">
            <WorkflowPreview variant={steps[activeStep].variant} />
          </div>
        </div>
      </div>
    </section>
  );
}
