import { api } from "@cmux/convex/api";
import fs from "fs/promises";
import os from "os";
import path from "path";
import { RepositoryManager } from "./repositoryManager.js";
import { convex } from "./utils/convexClient.js";
import { serverLogger } from "./utils/fileLogger.js";
import crypto from "crypto";

interface WorkspaceResult {
  success: boolean;
  worktreePath?: string;
  error?: string;
}

interface WorktreeInfo {
  appDataPath: string;
  projectsPath: string;
  projectPath: string;
  originPath: string;
  worktreesPath: string;
  branchName: string;
  worktreePath: string;
  repoName: string;
}

async function getAppDataPath(): Promise<string> {
  const appName = "manaflow3";
  const platform = process.platform;

  if (platform === "darwin") {
    return path.join(os.homedir(), "Library", "Application Support", appName);
  } else if (platform === "win32") {
    return path.join(process.env.APPDATA || "", appName);
  } else {
    return path.join(os.homedir(), ".config", appName);
  }
}

function extractRepoName(repoUrl: string): string {
  const match = repoUrl.match(/([^/]+)\.git$/);
  if (match) {
    return match[1];
  }

  const parts = repoUrl.split("/");
  return parts[parts.length - 1] || "unknown-repo";
}

async function detectAvailableProvider(): Promise<
  | { provider: "openai"; model: string; envVar: "OPENAI_API_KEY"; key?: string }
  | { provider: "anthropic"; model: string; envVar: "ANTHROPIC_API_KEY"; key?: string }
  | { provider: "gemini"; model: string; envVar: "GEMINI_API_KEY"; key?: string }
  | null
> {
  try {
    const keyMap = await convex.query(api.apiKeys.getAllForAgents);
    if (keyMap && typeof keyMap === "object") {
      if (keyMap.OPENAI_API_KEY) {
        return { provider: "openai", model: "gpt-5-nano", envVar: "OPENAI_API_KEY", key: keyMap.OPENAI_API_KEY };
      }
      if (keyMap.ANTHROPIC_API_KEY) {
        return { provider: "anthropic", model: "claude-3-5-haiku-20241022", envVar: "ANTHROPIC_API_KEY", key: keyMap.ANTHROPIC_API_KEY };
      }
      if (keyMap.GEMINI_API_KEY) {
        return { provider: "gemini", model: "gemini-2.5-flash-lite", envVar: "GEMINI_API_KEY", key: keyMap.GEMINI_API_KEY };
      }
    }
  } catch (e) {
    serverLogger.warn("Failed to detect available provider from Convex apiKeys:", e);
  }
  // Also consider environment variables if present
  if (process.env.OPENAI_API_KEY) {
    return { provider: "openai", model: "gpt-5-nano", envVar: "OPENAI_API_KEY", key: process.env.OPENAI_API_KEY } as const;
  }
  if (process.env.ANTHROPIC_API_KEY) {
    return { provider: "anthropic", model: "claude-3-5-haiku-20241022", envVar: "ANTHROPIC_API_KEY", key: process.env.ANTHROPIC_API_KEY } as const;
  }
  if ((process.env.GEMINI_API_KEY || process.env.GOOGLE_API_KEY)) {
    return { provider: "gemini", model: "gemini-2.5-flash-lite", envVar: "GEMINI_API_KEY", key: process.env.GEMINI_API_KEY || process.env.GOOGLE_API_KEY } as const;
  }
  return null;
}

function slugify(input: string, maxLen = 50): string {
  const base = input
    .toLowerCase()
    .replace(/[^a-z0-9\s-]/g, "")
    .trim()
    .replace(/\s+/g, "-")
    .replace(/-+/g, "-");
  return base.slice(0, maxLen).replace(/^-+|-+$/g, "");
}

async function maybeGenerateDescriptiveName(taskDescription?: string): Promise<string | null> {
  if (!taskDescription || taskDescription.trim().length === 0) return null;
  const provider = await detectAvailableProvider();
  if (!provider) return slugify(taskDescription, 40);

  try {
    const prompt = `Generate a short, kebab-case git branch slug (no spaces, only [a-z0-9-]) of at most 6 words and 40 chars max that describes this task: "${taskDescription}". Only return the slug.`;
    if (provider.provider === "openai") {
      const fetchFn = globalThis.fetch || (await import("node-fetch")).default as any;
      const resp = await fetchFn("https://api.openai.com/v1/chat/completions", {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          Authorization: `Bearer ${provider.key}`,
        },
        body: JSON.stringify({
          model: provider.model,
          messages: [{ role: "user", content: prompt }],
          max_tokens: 20,
          temperature: 0.2,
        }),
      });
      const data = await resp.json();
      const text: string = data?.choices?.[0]?.message?.content || "";
      return slugify(text || taskDescription, 40);
    }
    if (provider.provider === "anthropic") {
      const fetchFn = globalThis.fetch || (await import("node-fetch")).default as any;
      const resp = await fetchFn("https://api.anthropic.com/v1/messages", {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          "x-api-key": provider.key!,
          "anthropic-version": "2023-06-01",
        },
        body: JSON.stringify({
          model: provider.model,
          max_tokens: 20,
          temperature: 0.2,
          messages: [{ role: "user", content: prompt }],
        }),
      });
      const data = await resp.json();
      const text: string = data?.content?.[0]?.text || "";
      return slugify(text || taskDescription, 40);
    }
    if (provider.provider === "gemini") {
      const fetchFn = globalThis.fetch || (await import("node-fetch")).default as any;
      const url = `https://generativelanguage.googleapis.com/v1beta/models/${provider.model}:generateContent?key=${provider.key}`;
      const resp = await fetchFn(url, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          contents: [{ parts: [{ text: prompt }] }],
          generationConfig: { temperature: 0.2, maxOutputTokens: 20 },
        }),
      });
      const data = await resp.json();
      const text: string = data?.candidates?.[0]?.content?.parts?.[0]?.text || "";
      return slugify(text || taskDescription, 40);
    }
  } catch (e) {
    serverLogger.warn("Failed to generate descriptive branch name via provider:", e);
  }
  return slugify(taskDescription, 40);
}

export async function getWorktreePath(args: {
  repoUrl: string;
  branch?: string;
  taskDescription?: string;
}): Promise<WorktreeInfo> {
  // Check for custom worktree path setting
  const settings = await convex.query(api.workspaceSettings.get);

  let projectsPath: string;

  if (settings?.worktreePath) {
    // Use custom path, expand ~ to home directory
    const expandedPath = settings.worktreePath.replace(/^~/, os.homedir());
    projectsPath = expandedPath;
  } else {
    // Use default path: ~/cmux
    projectsPath = path.join(os.homedir(), "cmux");
  }

  const repoName = extractRepoName(args.repoUrl);
  const projectPath = path.join(projectsPath, repoName);
  const originPath = path.join(projectPath, "origin");
  const worktreesPath = path.join(projectPath, "worktrees");

  // Build base slug from taskDescription using cheap LLM or fallback
  const candidate = await maybeGenerateDescriptiveName(args.taskDescription);
  const baseSlug = candidate || `task-${Date.now()}`;
  const prefix = (settings?.branchPrefix || "").trim();
  const prefixPart = prefix ? `${slugify(prefix, 20)}-` : "";

  // Ensure uniqueness by appending short random suffix
  const shortId = crypto.randomBytes(3).toString("hex");
  let branchName = `${prefixPart}${baseSlug}-${shortId}`
    .toLowerCase()
    .replace(/[^a-z0-9-]/g, "-")
    .replace(/--+/g, "-")
    .replace(/^-+|-+$/g, "");

  // Ensure the worktree folder is unique; if exists, append another nonce
  let worktreePath = path.join(worktreesPath, branchName);
  try {
    const stat = await fs.stat(worktreePath);
    if (stat) {
      const extra = crypto.randomBytes(2).toString("hex");
      branchName = `${branchName}-${extra}`;
      worktreePath = path.join(worktreesPath, branchName);
    }
  } catch {
    // does not exist -> fine
  }

  // For consistency, still return appDataPath even if not used for custom paths
  const appDataPath = await getAppDataPath();

  return {
    appDataPath,
    projectsPath,
    projectPath,
    originPath,
    worktreesPath,
    branchName,
    worktreePath,
    repoName,
  };
}

export async function setupProjectWorkspace(args: {
  repoUrl: string;
  branch?: string;
  worktreeInfo: WorktreeInfo;
}): Promise<WorkspaceResult> {
  try {
    const { worktreeInfo } = args;
    const repoManager = RepositoryManager.getInstance();

    // Check if the projects path exists and has non-git content
    try {
      const stats = await fs.stat(worktreeInfo.projectsPath);
      if (stats.isDirectory()) {
        // Check if it contains non-git repositories
        const entries = await fs.readdir(worktreeInfo.projectsPath);
        for (const entry of entries) {
          const entryPath = path.join(worktreeInfo.projectsPath, entry);
          const entryStats = await fs.stat(entryPath);
          if (entryStats.isDirectory()) {
            // Check if it's a git repository structure we expect
            const hasOrigin = await fs
              .access(path.join(entryPath, "origin"))
              .then(() => true)
              .catch(() => false);
            const hasWorktrees = await fs
              .access(path.join(entryPath, "worktrees"))
              .then(() => true)
              .catch(() => false);

            if (!hasOrigin && !hasWorktrees) {
              // This directory has unexpected content
              return {
                success: false,
                error: `The directory ${worktreeInfo.projectsPath} contains existing files that are not git worktrees. Please choose a different location in settings or move the existing files.`,
              };
            }
          }
        }
      }
    } catch {
      // Directory doesn't exist, which is fine
    }

    await fs.mkdir(worktreeInfo.projectPath, { recursive: true });
    await fs.mkdir(worktreeInfo.worktreesPath, { recursive: true });

    // Use RepositoryManager to handle clone/fetch with deduplication
    await repoManager.ensureRepository(
      args.repoUrl,
      worktreeInfo.originPath,
      args.branch
    );

    // Get the default branch if not specified
    const baseBranch = args.branch || await repoManager.getDefaultBranch(worktreeInfo.originPath);

    // Create the worktree
    await repoManager.createWorktree(
      worktreeInfo.originPath,
      worktreeInfo.worktreePath,
      worktreeInfo.branchName,
      baseBranch
    );

    return { success: true, worktreePath: worktreeInfo.worktreePath };
  } catch (error) {
    serverLogger.error("Failed to setup workspace:", error);
    return {
      success: false,
      error: error instanceof Error ? error.message : "Unknown error",
    };
  }
}
