import { api } from "@cmux/convex/api";
import { convex } from "./convexClient.js";
import path from "node:path";
import fs from "node:fs/promises";

// Providers and cheap models
// - OpenAI: gpt-5-nano via @openai/codex
// - Anthropic: claude-3-5-haiku-20241022 via @anthropic-ai/claude-code
// - Gemini: gemini-2.5-flash-lite via @google/gemini-cli

type Provider = "openai" | "anthropic" | "gemini";

interface NameSuggestOptions {
  taskDescription: string;
  repoName: string;
  worktreesPath: string;
  branchPrefix?: string | null;
  originPath?: string;
}

function sanitizeSlug(input: string, maxLen = 40): string {
  const base = input
    .toLowerCase()
    .replace(/[^a-z0-9\s-]/g, "")
    .trim()
    .replace(/\s+/g, "-")
    .replace(/-+/g, "-");
  return base.substring(0, maxLen);
}

async function detectAvailableProvider(): Promise<{ provider: Provider | null; apiKeyEnv: string | null }>
{
  try {
    const keyMap = await convex.query(api.apiKeys.getAllForAgents);
    if (keyMap["OPENAI_API_KEY"] || process.env.OPENAI_API_KEY) {
      return { provider: "openai", apiKeyEnv: "OPENAI_API_KEY" };
    }
    if (keyMap["ANTHROPIC_API_KEY"] || process.env.ANTHROPIC_API_KEY) {
      return { provider: "anthropic", apiKeyEnv: "ANTHROPIC_API_KEY" };
    }
    if (keyMap["GEMINI_API_KEY"] || process.env.GEMINI_API_KEY || process.env.GOOGLE_API_KEY) {
      // Prefer GEMINI_API_KEY if present; fall back to GOOGLE_API_KEY
      return { provider: "gemini", apiKeyEnv: keyMap["GEMINI_API_KEY"] ? "GEMINI_API_KEY" : (process.env.GEMINI_API_KEY ? "GEMINI_API_KEY" : "GOOGLE_API_KEY") };
    }
  } catch {}
  return { provider: null, apiKeyEnv: null };
}

async function callLLMForName(provider: Provider, prompt: string): Promise<string | null> {
  // Run through underlying CLIs with cheap models. Use --yes/--force and no interactive behavior.
  // Return a single-line suggestion.
  const { exec } = await import("node:child_process");
  const { promisify } = await import("node:util");
  const execAsync = promisify(exec);

  try {
    if (provider === "openai") {
      const cmd = `bunx --yes @openai/codex --model gpt-5-nano --sandbox never "${prompt.replace(/"/g, '\\"')}" | head -n 1`;
      const { stdout } = await execAsync(cmd, { env: process.env });
      return stdout.trim();
    }
    if (provider === "anthropic") {
      const cmd = `bunx --yes @anthropic-ai/claude-code --model claude-3-5-haiku-20241022 --dangerously-skip-permissions "${prompt.replace(/"/g, '\\"')}" | head -n 1`;
      const { stdout } = await execAsync(cmd, { env: process.env });
      return stdout.trim();
    }
    if (provider === "gemini") {
      const cmd = `bunx --yes @google/gemini-cli --model gemini-2.5-flash-lite --prompt "${prompt.replace(/"/g, '\\"')}" | head -n 1`;
      const { stdout } = await execAsync(cmd, { env: process.env });
      return stdout.trim();
    }
  } catch {
    return null;
  }
  return null;
}

export async function ensureUniqueName(
  baseName: string,
  worktreesPath: string,
  originPath?: string
): Promise<{ branchName: string; worktreePath: string }>
{
  let attempt = 0;
  let current = baseName;
  while (true) {
    const candidatePath = path.join(worktreesPath, current);
    try {
      await fs.access(candidatePath);
      // Exists, try suffix
      attempt += 1;
      current = `${baseName}-${attempt}`;
      continue;
    } catch {
      // Directory does not exist; optionally check for existing branch in origin
      if (originPath) {
        try {
          const { exec } = await import("node:child_process");
          const { promisify } = await import("node:util");
          const execAsync = promisify(exec);
          // Check local refs (if repo initialized) and remote heads
          const checkLocal = `git -C "${originPath}" show-ref --verify --quiet refs/heads/${current}`;
          const checkRemote = `git -C "${originPath}" ls-remote --exit-code --heads origin ${current}`;
          try {
            await execAsync(checkLocal);
            // Local branch exists
            attempt += 1;
            current = `${baseName}-${attempt}`;
            continue;
          } catch {}
          try {
            await execAsync(checkRemote);
            // Remote branch exists
            attempt += 1;
            current = `${baseName}-${attempt}`;
            continue;
          } catch {}
        } catch {}
      }
      return { branchName: current, worktreePath: candidatePath };
    }
  }
}

export async function suggestBranchAndWorktree(options: NameSuggestOptions): Promise<{ branchName: string; worktreePath: string }>
{
  const { provider } = await detectAvailableProvider();

  const fallback = sanitizeSlug(options.taskDescription || options.repoName || "task");

  let suggested = fallback;
  if (provider) {
    const prompt = `Given this task: "${options.taskDescription}" for repo "${options.repoName}", propose a short, kebab-case branch name (no spaces, only [a-z0-9-]), 3-6 words, no prefix or ticket numbers.`;
    const llm = await callLLMForName(provider, prompt);
    if (llm) {
      const cleaned = sanitizeSlug(llm);
      if (cleaned.length >= 3) suggested = cleaned;
    }
  }

  // Apply optional prefix if provided and non-empty, but default to none
  const prefix = options.branchPrefix?.trim();
  const baseName = prefix ? `${sanitizeSlug(prefix, 20)}-${suggested}` : suggested;

  return await ensureUniqueName(baseName, options.worktreesPath, options.originPath);
}