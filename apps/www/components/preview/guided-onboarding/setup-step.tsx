"use client";

import { Check, ChevronDown } from "lucide-react";
import { useEffect, useState } from "react";

export type StepStatus = "pending" | "current" | "completed";

export interface SetupStepConfig {
  id: string;
  title: string;
  description: string;
  optional?: boolean;
  defaultValue?: string;
  placeholder?: string;
  docsUrl?: string;
}

interface SetupStepProps {
  step: SetupStepConfig;
  status: StepStatus;
  index: number;
  value: string;
  onChange: (value: string) => void;
  onVerify?: () => void;
  isVerifying?: boolean;
}

export function SetupStep({
  step,
  status,
  index,
  value,
  onChange,
  onVerify,
  isVerifying,
}: SetupStepProps) {
  const [isExpanded, setIsExpanded] = useState(status === "current");

  useEffect(() => {
    if (status === "current") {
      setIsExpanded(true);
    }
  }, [status]);

  const isCompleted = status === "completed";
  const isCurrent = status === "current";

  return (
    <div className="border-b border-neutral-200/70 dark:border-neutral-800 last:border-b-0">
      <button
        onClick={() => setIsExpanded((prev) => !prev)}
        className="w-full flex items-start gap-3 p-4 text-left hover:bg-neutral-50 dark:hover:bg-neutral-900/40 transition"
      >
        <div
          className={`h-7 w-7 rounded-full flex items-center justify-center text-[11px] font-medium ${
            isCompleted
              ? "bg-emerald-500/15 text-emerald-600 dark:text-emerald-400 border border-emerald-500/30"
              : isCurrent
                ? "bg-blue-500/10 text-blue-600 dark:text-blue-400 border border-blue-500/40"
                : "bg-white dark:bg-neutral-900 text-neutral-500 dark:text-neutral-400 border border-neutral-200 dark:border-neutral-700"
          }`}
        >
          {isCompleted ? <Check className="h-3.5 w-3.5" /> : index + 1}
        </div>
        <div className="flex-1">
          <div className="flex items-center gap-2">
            <span
              className={`text-sm font-medium ${
                isCurrent ? "text-neutral-900 dark:text-neutral-100" : "text-neutral-700 dark:text-neutral-300"
              }`}
            >
              {step.title}
            </span>
            {step.optional && (
              <span className="text-[10px] uppercase tracking-wide text-neutral-400 dark:text-neutral-500">
                Optional
              </span>
            )}
          </div>
          {step.description && (
            <p className="mt-1 text-xs text-neutral-500 dark:text-neutral-400">{step.description}</p>
          )}
        </div>
        <ChevronDown
          className={`w-4 h-4 text-neutral-400 transition-transform ${isExpanded ? "rotate-180" : ""}`}
        />
      </button>

      {isExpanded && (
        <div className="px-4 pb-4 pl-[52px]">
          <div className="rounded-lg border border-neutral-200/70 dark:border-neutral-800 bg-white dark:bg-neutral-900/60">
            <textarea
              value={value}
              onChange={(e) => onChange(e.target.value)}
              placeholder={step.placeholder}
              rows={3}
              className="w-full bg-transparent text-neutral-700 dark:text-neutral-200 placeholder:text-neutral-400 dark:placeholder:text-neutral-500 resize-none focus:outline-none px-3 py-2 text-xs font-mono"
            />
          </div>

          <div className="flex items-center gap-2 mt-3">
            {onVerify && (
              <button
                onClick={onVerify}
                disabled={isVerifying}
                className="px-3 py-1.5 text-xs font-medium bg-neutral-900 text-white hover:bg-neutral-800 dark:bg-neutral-200 dark:text-neutral-900 dark:hover:bg-neutral-100 rounded transition disabled:opacity-50"
              >
                {isVerifying ? "Saving..." : isCompleted ? "Completed" : "Mark done"}
              </button>
            )}
            {step.docsUrl && (
              <a
                href={step.docsUrl}
                target="_blank"
                rel="noopener noreferrer"
                className="text-xs text-neutral-500 hover:text-neutral-700 dark:text-neutral-400 dark:hover:text-neutral-200 transition flex items-center gap-1"
              >
                Docs
                <svg className="w-3 h-3" fill="none" viewBox="0 0 24 24" stroke="currentColor">
                  <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M10 6H6a2 2 0 00-2 2v10a2 2 0 002 2h10a2 2 0 002-2v-4M14 4h6m0 0v6m0-6L10 14" />
                </svg>
              </a>
            )}
          </div>
        </div>
      )}
    </div>
  );
}
