import { api } from "@cmux/convex/api";
import type { Doc, Id } from "@cmux/convex/dataModel";
import * as fs from "node:fs/promises";
import * as path from "node:path";
import { RepositoryManager } from "../repositoryManager.js";
import { getConvex } from "../utils/convexClient.js";
import { serverLogger } from "../utils/fileLogger.js";
import { getWorktreePath, setupProjectWorkspace } from "../workspace.js";

export type EnsureWorktreeResult = {
  run: Doc<"taskRuns">;
  task: Doc<"tasks">;
  worktreePath: string;
  branchName: string;
  baseBranch: string;
};

function sanitizeBranchName(name: string): string {
  return name.replace(/[^a-zA-Z0-9._/-]/g, "-");
}

// Deduplicate concurrent ensures for the same taskRunId within this process
const pendingEnsures = new Map<string, Promise<EnsureWorktreeResult>>();

export async function ensureRunWorktreeAndBranch(
  taskRunId: Id<"taskRuns">,
  teamSlugOrId: string
): Promise<EnsureWorktreeResult> {
  const key = String(taskRunId);
  const existing = pendingEnsures.get(key);
  if (existing) return existing;

  const p = (async (): Promise<EnsureWorktreeResult> => {
    const run = await getConvex().query(api.taskRuns.get, {
      teamSlugOrId,
      id: taskRunId,
    });
    if (!run) throw new Error("Task run not found");

    const task = await getConvex().query(api.tasks.getById, {
      teamSlugOrId,
      id: run.taskId,
    });
    if (!task) throw new Error("Task not found");

    // Determine base branch: prefer explicit task.baseBranch; otherwise detect later
    let baseBranch = task.baseBranch || "";
    const branchName = sanitizeBranchName(
      run.newBranch || `cmux-run-${String(taskRunId).slice(-8)}`
    );

    // Ensure worktree exists
    let worktreePath = run.worktreePath;
    let needsSetup = !worktreePath;

    // Check if the worktree directory actually exists (handle manual deletion case)
    if (worktreePath) {
      try {
        await fs.access(worktreePath);
        // Also check if it's a valid git directory
        await fs.access(path.join(worktreePath, ".git"));
      } catch {
        serverLogger.warn(
          `Worktree path ${worktreePath} doesn't exist or is not a git directory, recreating...`
        );
        needsSetup = true;
        worktreePath = undefined;
      }
    }

    if (needsSetup) {
      // Derive repo URL from task.projectFullName
      if (!task.projectFullName) {
        throw new Error("Missing projectFullName to set up worktree");
      }
      const repoUrl = `https://github.com/${task.projectFullName}.git`;
      const worktreeInfo = await getWorktreePath(
        {
          repoUrl,
          branch: branchName,
        },
        teamSlugOrId
      );

      const res = await setupProjectWorkspace({
        repoUrl,
        branch: baseBranch || undefined,
        worktreeInfo,
      });
      if (!res.success || !res.worktreePath) {
        throw new Error(res.error || "Failed to set up worktree");
      }
      worktreePath = res.worktreePath;
      await getConvex().mutation(api.taskRuns.updateWorktreePath, {
        teamSlugOrId,
        id: run._id,
        worktreePath,
      });

      // If baseBranch wasn't specified, detect it now from the origin repo
      if (!baseBranch) {
        const repoMgr = RepositoryManager.getInstance();
        baseBranch = await repoMgr.getDefaultBranch(worktreeInfo.originPath);
      }
    }

    // If worktree already existed and baseBranch is still empty, detect from the worktree
    if (!baseBranch && worktreePath) {
      const repoMgr = RepositoryManager.getInstance();
      baseBranch = await repoMgr.getDefaultBranch(worktreePath);
    }

    // Ensure worktreePath is defined before proceeding
    if (!worktreePath) {
      throw new Error("Failed to establish worktree path");
    }

    // Ensure we're on the correct branch without discarding changes
    const repoMgr = RepositoryManager.getInstance();
    try {
      const currentBranch = await repoMgr.getCurrentBranch(worktreePath);
      if (currentBranch !== branchName) {
        try {
          // Try to create a new branch
          await repoMgr.executeGitCommand(`git checkout -b ${branchName}`, {
            cwd: worktreePath,
          });
        } catch {
          // If branch already exists, just switch to it
          await repoMgr.executeGitCommand(`git checkout ${branchName}`, {
            cwd: worktreePath,
          });
        }
      }
    } catch (e: unknown) {
      const err = e as { message?: string; stderr?: string };
      serverLogger.error(
        `[ensureRunWorktree] Failed to ensure branch: ${err?.stderr || err?.message || "unknown"}`
      );
      console.error(e);
      throw new Error(
        `Failed to ensure branch: ${err?.stderr || err?.message || "unknown"}`
      );
    }

    return { run, task, worktreePath, branchName, baseBranch };
  })();

  pendingEnsures.set(key, p);
  try {
    return await p;
  } finally {
    pendingEnsures.delete(key);
  }
}
