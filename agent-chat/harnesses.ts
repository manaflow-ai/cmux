import { homedir } from "node:os";
import { existsSync } from "node:fs";
import { join, relative } from "node:path";

export interface HarnessRecommendation {
  id: string;
  label: string;
  installed: boolean;
  priority: number;
  triggers: string[];
  reason: string;
  kind: "workflow";
  benefit: string;
  tags: string[];
  provider?: string;
  evidence?: string;
  installCommand?: string;
}

export interface HarnessDiscoveryOptions {
  cwd?: string;
  home?: string;
  exists?: (path: string) => boolean;
  which?: (command: string) => string | undefined;
}

interface WorkflowDefinition {
  id: string;
  label: string;
  provider: string;
  command?: string;
  projectPaths: string[];
  globalPaths: string[];
  tags: string[];
  benefit: string;
  installCommand?: string;
}

const workflowDefinitions: WorkflowDefinition[] = [
  {
    id: "oh-my-pi",
    label: "oh-my-pi",
    provider: "pi",
    command: "omp",
    projectPaths: [".omp"],
    globalPaths: ["~/.omp"],
    tags: ["compaction", "memory", "lsp", "multi-provider"],
    benefit: "keeps compaction, memory, and provider routing available in the session",
    installCommand: "curl -fsSL https://omp.sh/install | sh",
  },
  {
    id: "oh-my-openagent",
    label: "oh-my-openagent",
    provider: "opencode",
    projectPaths: [".opencode/oh-my-openagent.json", ".opencode/oh-my-openagent.jsonc", ".opencode/oh-my-opencode.json", ".opencode/oh-my-opencode.jsonc"],
    globalPaths: ["~/.config/opencode/oh-my-openagent.json", "~/.config/opencode/oh-my-openagent.jsonc", "~/.config/opencode/oh-my-opencode.json", "~/.config/opencode/oh-my-opencode.jsonc"],
    tags: ["teams", "parallel", "fallback", "recovery"],
    benefit: "adds parallel specialists, visible team work, and recovery around OpenCode",
  },
  {
    id: "oh-my-claudecode",
    label: "oh-my-claudecode",
    provider: "claude",
    command: "omc",
    projectPaths: [".claude/plugins/oh-my-claudecode", ".claude/plugins/oh-my-claude-sisyphus"],
    globalPaths: ["~/.claude/plugins/oh-my-claudecode", "~/.claude/plugins/oh-my-claude-sisyphus"],
    tags: ["intent", "teams", "workflow", "verification"],
    benefit: "adds intent-driven orchestration, teams, and verification rails to Claude Code",
    installCommand: "npm install -g oh-my-claude-sisyphus",
  },
  {
    id: "superpowers",
    label: "Superpowers",
    provider: "claude",
    projectPaths: [".agents/plugins/superpowers", ".claude/plugins/superpowers", ".codex/plugins/superpowers"],
    globalPaths: ["~/.agents/skills/superpowers", "~/.claude/plugins/superpowers", "~/.codex/plugins/superpowers"],
    tags: ["planning", "tdd", "subagents", "verification"],
    benefit: "adds structured planning, TDD, subagents, and review checkpoints",
    installCommand: "install from the Superpowers plugin marketplace",
  },
];

function expandPath(path: string, cwd: string, home: string): string {
  if (path.startsWith("~/")) return join(home, path.slice(2));
  if (path.startsWith(".")) return join(cwd, path);
  return path;
}

function evidenceLabel(path: string, cwd: string, home: string): string {
  const absolute = expandPath(path, cwd, home);
  if (absolute === cwd || absolute.startsWith(`${cwd}/`)) return `found ${relative(cwd, absolute) || "."}`;
  if (absolute === home || absolute.startsWith(`${home}/`)) return `found ~/${relative(home, absolute)}`;
  return `found ${absolute}`;
}

function firstExisting(paths: string[], cwd: string, home: string, exists: (path: string) => boolean): string | undefined {
  return paths.find((path) => exists(expandPath(path, cwd, home)));
}

/**
 * Discover installed workflow harnesses without starting a process or reading
 * project contents. A result is only returned when a command or config path
 * gives cmux concrete evidence that the workflow is available.
 */
export function discoverHarnesses(options: HarnessDiscoveryOptions = {}): HarnessRecommendation[] {
  const cwd = options.cwd ?? process.cwd();
  const home = options.home ?? homedir();
  const exists = options.exists ?? existsSync;
  const which = options.which ?? ((command: string) => Bun.which(command, { PATH: process.env.PATH }) ?? undefined);
  return workflowDefinitions.flatMap((definition) => {
    const projectEvidence = firstExisting(definition.projectPaths, cwd, home, exists);
    const globalEvidence = firstExisting(definition.globalPaths, cwd, home, exists);
    const commandEvidence = definition.command ? which(definition.command) : undefined;
    const evidencePath = projectEvidence ?? globalEvidence;
    if (!evidencePath && !commandEvidence) return [];
    const evidence = evidencePath
      ? evidenceLabel(evidencePath, cwd, home)
      : `${definition.command} is installed`;
    return [{
      id: definition.id,
      label: definition.label,
      installed: true,
      priority: projectEvidence ? 0 : 1,
      triggers: ["/", "$"],
      kind: "workflow" as const,
      reason: `${evidence}; ${definition.benefit}`,
      benefit: definition.benefit,
      tags: definition.tags,
      provider: definition.provider,
      evidence,
      ...(definition.installCommand ? { installCommand: definition.installCommand } : {}),
    }];
  }).sort((a, b) => a.priority - b.priority || a.label.localeCompare(b.label));
}
