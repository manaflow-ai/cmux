import type { CSSProperties } from "react";
import { useCallback, useMemo } from "react";
import { Command as CommandIcon, Search } from "lucide-react";

import { AgentLogo } from "@/components/icons/agent-logos";
import { requestOpenCommandPalette } from "@/lib/command-palette-events";

type DashboardTopBarProps = {
  agentNames: string[];
};

const dragStyle = { WebkitAppRegion: "drag" } as CSSProperties;
const noDragStyle = { WebkitAppRegion: "no-drag" } as CSSProperties;

const vendorKey = (agentName: string): string => {
  const lower = agentName.toLowerCase();
  if (lower.startsWith("codex/")) return "openai";
  if (lower.startsWith("claude/")) return "claude";
  if (lower.startsWith("gemini/")) return "gemini";
  if (lower.startsWith("opencode/")) return "opencode";
  if (lower.startsWith("qwen/")) return "qwen";
  if (lower.startsWith("cursor/")) return "cursor";
  if (lower.startsWith("amp")) return "amp";
  return "other";
};

export function DashboardTopBar({ agentNames }: DashboardTopBarProps) {
  const displayAgents = useMemo(() => {
    const seen = new Set<string>();
    const uniqueAgents: string[] = [];

    for (const agent of agentNames) {
      const key = vendorKey(agent);
      if (seen.has(key)) continue;
      seen.add(key);
      uniqueAgents.push(agent);
      if (uniqueAgents.length >= 4) break;
    }

    return uniqueAgents;
  }, [agentNames]);

  const handleOpen = useCallback(() => {
    requestOpenCommandPalette();
  }, []);

  return (
    <div
      className="min-h-[52px] border-b border-neutral-200/70 dark:border-neutral-800/50 flex items-center justify-center relative select-none"
      style={dragStyle}
    >
      <div className="absolute left-0 w-20 h-full" style={dragStyle} />
      <div className="w-full max-w-[560px] px-3" style={noDragStyle}>
        <button
          type="button"
          onClick={handleOpen}
          className="group flex h-10 w-full items-center gap-3 rounded-full border border-neutral-200/80 dark:border-neutral-700/70 bg-neutral-100/80 dark:bg-neutral-800/70 px-3 text-sm text-neutral-600 dark:text-neutral-300 shadow-sm transition-colors hover:bg-neutral-100 dark:hover:bg-neutral-800 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-neutral-400/40 dark:focus-visible:ring-neutral-600/40"
        >
          <span className="flex items-center gap-2">
            <Search className="h-4 w-4 text-neutral-500 dark:text-neutral-400" />
            <span className="text-sm font-medium">Command + K</span>
          </span>
          <span className="ml-auto flex items-center gap-2">
            {displayAgents.length > 0 ? (
              <span className="flex items-center -space-x-2">
                {displayAgents.map((agent) => (
                  <span
                    key={agent}
                    className="inline-flex h-6 w-6 items-center justify-center rounded-full border border-neutral-200/70 bg-white/80 dark:border-neutral-700/70 dark:bg-neutral-900/70"
                  >
                    <AgentLogo
                      agentName={agent}
                      className="h-3.5 w-3.5 text-neutral-900 dark:text-neutral-100"
                    />
                  </span>
                ))}
              </span>
            ) : null}
            <span className="inline-flex items-center gap-1 rounded-md border border-neutral-200/70 bg-white/70 px-2 py-0.5 text-[11px] font-semibold text-neutral-500 dark:border-neutral-700/70 dark:bg-neutral-900/70 dark:text-neutral-300">
              <CommandIcon className="h-3 w-3" />
              <span>K</span>
            </span>
          </span>
        </button>
      </div>
    </div>
  );
}
