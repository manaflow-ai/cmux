import type { Block, CommandGroup, Provider, ProviderCapabilities, SessionActions, SessionOption } from "./session";

export const galleryProviders: Provider[] = [
  { id: "claude", label: "Claude Code", installed: true, iconUrl: "/icons/claude", installCommand: "npm i -g @anthropic-ai/claude-code" },
  { id: "codex", label: "Codex", installed: true, iconUrl: "/icons/codex", iconDarkUrl: "/icons/codex?dark=1", installCommand: "npm i -g @openai/codex" },
  { id: "opencode", label: "OpenCode", installed: true, iconUrl: "/icons/opencode", installCommand: "npm i -g opencode-ai" },
  { id: "pi", label: "pi", installed: true, iconUrl: "/icons/pi", installCommand: "npm i -g @mariozechner/pi" },
  { id: "gemini", label: "Gemini", installed: false, installCommand: "npm i -g @google/gemini-cli" },
];

const modelChoices = [
  { value: "claude-fable-5", label: "Claude Fable 5", description: "Latest fast model" },
  { value: "claude-opus-4-8", label: "Claude Opus 4.8", description: "Largest reasoning model" },
  { value: "claude-opus-4-7", label: "Claude Opus 4.7", disabled: true, disabledReason: "Upgrade Claude Code to use Opus 4.7" },
  { value: "claude-sonnet-5", label: "Claude Sonnet 5", description: "Default balanced model" },
  { value: "claude-haiku-4-5", label: "Claude Haiku 4.5", description: "Fast small model" },
];

export const galleryOptions: Record<string, SessionOption[]> = {
  claude: [
    { id: "model", label: "Model", kind: "select", value: "claude-sonnet-5", choices: modelChoices },
    { id: "context", label: "Context", kind: "select", role: "context", value: "200k", choices: [{ value: "200k", label: "200k" }, { value: "1m", label: "1M" }] },
    { id: "effort", label: "Effort", kind: "select", role: "effort", value: "high", choices: ["low", "medium", "high", "xhigh", "max"].map((v) => ({ value: v, label: v === "xhigh" ? "Extra high" : v[0].toUpperCase() + v.slice(1) })) },
    { id: "fastMode", label: "Fast mode", kind: "toggle", value: true },
    { id: "permissionMode", label: "Permission mode", kind: "select", value: "plan", choices: ["default", "acceptEdits", "plan", "bypassPermissions", "dontAsk", "auto"].map((v) => ({ value: v, label: v })) },
    { id: "thinking", label: "Thinking budget", role: "thinking-budget", kind: "select", value: "16k", choices: [{ value: "off", label: "Off" }, { value: "4k", label: "4k" }, { value: "16k", label: "16k" }, { value: "32k", label: "32k" }] },
  ],
  codex: [
    { id: "model", label: "Model", kind: "select", value: "gpt-5.4-codex", choices: [
      { value: "gpt-5.5", label: "GPT-5.5", description: "Frontier model" },
      { value: "gpt-5.4-codex", label: "GPT-5.4 Codex", description: "Best coding model" },
      { value: "gpt-5.4-mini", label: "GPT-5.4 Mini", description: "Fast and cheap" },
      { value: "o4-preview", label: "O4 Preview", disabled: true, disabledReason: "Unavailable for this account" },
    ] },
    { id: "effort", label: "Effort", kind: "select", role: "effort", value: "medium", choices: ["low", "medium", "high", "xhigh"].map((v) => ({ value: v, label: v === "xhigh" ? "Extra high" : v[0].toUpperCase() + v.slice(1) })) },
    { id: "fastMode", label: "Fast mode", kind: "toggle", value: false },
    { id: "approvals", label: "Approvals", kind: "select", value: "on-request", choices: [
      { value: "untrusted", label: "Untrusted" },
      { value: "on-request", label: "On request" },
      { value: "on-failure", label: "On failure" },
      { value: "never", label: "Never" },
    ] },
    { id: "sandbox", label: "Sandbox", kind: "select", value: "workspace-write", choices: [
      { value: "read-only", label: "Read only" },
      { value: "workspace-write", label: "Workspace write" },
      { value: "danger-full-access", label: "Danger full access" },
    ] },
  ],
  opencode: [
    { id: "model", label: "Model", kind: "select", value: "anthropic/claude-sonnet-5", choices: [
      { value: "anthropic/claude-sonnet-5", label: "Anthropic / Claude Sonnet 5" },
      { value: "openai/gpt-5.4", label: "OpenAI / GPT-5.4" },
      { value: "google/gemini-3-pro-preview", label: "Google / Gemini 3 Pro Preview" },
    ] },
    { id: "mode", label: "Mode", kind: "select", value: "build", choices: [{ value: "build", label: "Build" }, { value: "plan", label: "Plan" }] },
    { id: "autoApprove", label: "Auto-approve", kind: "toggle", role: "approval", value: true },
  ],
  pi: [
    { id: "model", label: "Model", kind: "select", value: "openai/gpt-5.4", choices: [
      { value: "openai/gpt-5.4", label: "OpenAI / GPT-5.4" },
      { value: "anthropic/claude-sonnet-5", label: "Anthropic / Claude Sonnet 5" },
      { value: "google/gemini-3-flash-preview", label: "Google / Gemini 3 Flash Preview" },
    ] },
    { id: "thinking", label: "Thinking", kind: "select", role: "effort", value: "minimal", choices: ["minimal", "low", "medium", "high", "xhigh"].map((v) => ({ value: v, label: v === "xhigh" ? "Extra high" : v[0].toUpperCase() + v.slice(1) })) },
  ],
  gemini: [
    { id: "model", label: "Model", kind: "select", value: "gemini-3.1-pro-preview", choices: [
      { value: "gemini-3.1-pro-preview", label: "Gemini 3.1 Pro Preview" },
      { value: "gemini-3-pro-preview", label: "Gemini 3 Pro Preview" },
      { value: "gemini-3-flash-preview", label: "Gemini 3 Flash Preview" },
    ] },
    { id: "mode", label: "Mode", kind: "select", value: "plan", choices: [{ value: "build", label: "Build" }, { value: "plan", label: "Plan" }] },
    { id: "autoApprove", label: "Auto-approve", kind: "toggle", role: "approval", value: false },
  ],
};

export const galleryCapabilities: Record<string, ProviderCapabilities> = Object.fromEntries(
  Object.entries(galleryOptions).map(([provider, options]) => [provider, { options, triggers: provider === "codex" ? ["/", "$", "@"] : ["/", "@"] }]),
);

export const galleryCommands: CommandGroup[] = [
  { trigger: "/", commands: Array.from({ length: 16 }, (_, i) => ({ name: ["init", "compact", "review", "test", "explain", "fix", "plan", "search"][i % 8] + (i > 7 ? `-${i}` : ""), description: "Slash command with enough text to exercise truncation and fuzzy filtering" })) },
  { trigger: "$", commands: Array.from({ length: 14 }, (_, i) => ({ name: ["security", "docs", "refactor", "tests", "frontend", "release", "debug"][i % 7] + (i > 6 ? `-${i}` : ""), description: "Codex skill from the mock catalog" })) },
  { trigger: "@", commands: [
    ...["src/App.tsx", "src/session.ts", "src/gallery.tsx", "src/gallery-fixtures.ts", "adapters/claude.ts", "adapters/codex.ts", "adapters/acp.ts", "test/options.e2e.ts"],
    ...Array.from({ length: 18 }, (_, i) => `packages/very/long/path/example-file-${i}.typescript`),
  ].map((name) => ({ name, description: "File reference" })) },
];

const assistantMarkdown = (i: number) => `### Review pass ${i}

This assistant message mixes **markdown**, inline \`code_${i}\`, links like [cmux](https://cmux.dev), and enough prose to wrap across several lines in the transcript.

- Bullet item one for spacing checks
- Bullet item two with \`inline_code\`

1. Ordered item one
2. Ordered item two

| area | state | note |
| --- | --- | --- |
| parser | ok | handles tables |
| renderer | watch | preserves spacing |

\`\`\`ts
export function deliberatelyWideLine${i}() {
  return "this string is intentionally long enough to force horizontal scrolling in a code block inside the gallery transcript ${"x".repeat(120)}";
}
\`\`\``;

export const longConversationBlocks: Block[] = Array.from({ length: 22 }, (_, i): Block[] => [
  { kind: "user", text: i % 3 === 0 ? `Please inspect pass ${i} and keep the exact token zebra-${i}.` : `Short follow-up ${i}.` },
  { kind: "thinking", text: `Considering file graph ${i}\nChecking edge cases and constraints.`, open: i % 2 === 0 },
  { kind: "tool", toolId: `tool-${i}-a`, name: i % 2 ? "rg" : "bun test", detail: i % 2 ? "searching for option state" : "running focused tests", status: i % 5 === 0 ? "fail" : "ok", out: `line 1: output from pass ${i}\nline 2: ${"long output ".repeat(24)}` },
  { kind: "assistant", text: assistantMarkdown(i), open: false },
  { kind: "footer", text: i % 4 === 0 ? "" : `${1800 + i} in · ${120 + i} out · ${(1.2 + i / 10).toFixed(1)}s` },
  ...(i % 6 === 0 ? [{ kind: "status", text: `Steered mid-turn with extra instruction ${i}` } as Block] : []),
]).flat();

longConversationBlocks.push(
  { kind: "tool", toolId: "running-tail", name: "shell", detail: "still running at transcript tail", status: "running" },
  { kind: "files", files: [
    { path: "src/App.tsx", adds: 42, dels: 9, status: "modified" },
    { path: "src/ChatMarkdown.tsx", adds: 120, dels: 0, status: "added" },
    { path: "public/app.css", adds: 88, dels: 12, status: "modified" },
  ] },
  { kind: "error", text: "Example adapter error with enough text to show wrapping in the error block." },
);

export const activityScenarios: { id: string; label: string; status: string; blocks: Block[] }[] = [
  { id: "pre-first-token", label: "Pre-first-token Thinking", status: "running", blocks: [{ kind: "user", text: "Start a slow Claude turn." }] },
  { id: "thinking-elapsed", label: "Thinking with elapsed counter", status: "running", blocks: [{ kind: "user", text: "Slow turn that has waited." }] },
  { id: "reasoning", label: "Reasoning under open thinking", status: "running", blocks: [{ kind: "user", text: "Reason out loud." }, { kind: "thinking", text: "I am tracing the plan and checking the constraints.", open: true }] },
  { id: "tool-running", label: "Tool running hides indicator", status: "running", blocks: [{ kind: "user", text: "Run tests." }, { kind: "tool", toolId: "t", name: "bun test", detail: "options.e2e.ts", status: "running" }] },
  { id: "between-phases", label: "Between phases", status: "running", blocks: [{ kind: "user", text: "Use a tool then continue." }, { kind: "tool", toolId: "t2", name: "rg", detail: "done", status: "ok", out: "matched 4 files" }] },
  { id: "done", label: "Done", status: "idle", blocks: [{ kind: "user", text: "Ping." }, { kind: "assistant", text: "PONG", open: false }, { kind: "footer", text: "10 in · 1 out · 0.6s" }] },
  { id: "error", label: "Error", status: "idle", blocks: [{ kind: "user", text: "Fail." }, { kind: "error", text: "Mock failure block." }] },
  { id: "exited", label: "Exited", status: "exited", blocks: [{ kind: "status", text: "Session exited." }] },
];

export const turnSummaryBlocks: Block[] = [
  { kind: "user", text: "Please inspect the repository picker and make the smallest fix." },
  { kind: "assistant", text: "I'll inspect the picker flow first, then make the smallest targeted edit.", open: false },
  { kind: "tool", toolId: "read-agents", name: "cat", detail: "AGENTS.md", status: "ok", out: "Read repository instructions and scoped rules." },
  { kind: "tool", toolId: "search-picker", name: "rg", detail: "RepositoryPicker", status: "ok", out: "Sources/RepositoryPicker.tsx\nSources/WorkspaceView.swift" },
  { kind: "tool", toolId: "list-files", name: "ls", detail: "Sources", status: "ok", out: "RepositoryPicker.tsx\nWorkspaceView.swift\n" },
  { kind: "tool", toolId: "edit-picker", name: "apply_patch", detail: "RepositoryPicker.tsx +1 -1", status: "ok", out: "*** Begin Patch\n*** Update File: RepositoryPicker.tsx\n+fixed\n-old\n*** End Patch" },
  { kind: "assistant", text: "Updated the picker to preserve the selected repository while filtering.", open: false },
  { kind: "footer", text: "1432 in · 82 out · 4.2s" },
];

export const stressConversationBlocks: Block[] = Array.from({ length: 250 }, (_, i): Block[] => [
  { kind: "user", text: `Stress turn ${i}: keep virtualization smooth.` },
  { kind: "tool", toolId: `stress-rg-${i}`, name: "rg", detail: `query-${i}`, status: "ok", out: `match ${i}\n`.repeat(3) },
  { kind: "tool", toolId: `stress-cat-${i}`, name: "cat", detail: `src/file-${i}.ts`, status: "ok", out: `file ${i}\n`.repeat(2) },
  { kind: "assistant", text: `Stress response ${i} with **markdown** and \`inline code\`.`, open: false },
  { kind: "footer", text: `${200 + i} in · ${20 + i} out · 0.${i % 9}s` },
]).flat();

export const galleryActions: SessionActions = { fork: true };
