import { api } from "@cmux/convex/api";
import type { Id } from "@cmux/convex/dataModel";
import fs from "node:fs/promises";
import path from "node:path";
import { RepositoryManager } from "../repositoryManager";
import { getProjectPaths, getWorktreePath, setupProjectWorkspace } from "../workspace";
import { getConvex } from "./convexClient";
import { serverLogger } from "./fileLogger";

interface PreparedEnvironmentWorkspace {
  targetPath: string;
  projectsRoot: string;
  repoWorktrees: Array<{
    repoFullName: string;
    repoUrl: string;
    worktreePath: string;
    branch: string;
  }>;
  environmentName: string;
}

export async function prepareEnvironmentWorkspace({
  environmentId,
  teamSlugOrId,
}: {
  environmentId: Id<"environments">;
  teamSlugOrId: string;
}): Promise<PreparedEnvironmentWorkspace> {
  const environment = await getConvex().query(api.environments.get, {
    teamSlugOrId,
    id: environmentId,
  });

  if (!environment) {
    throw new Error("Environment not found");
  }

  const repoFullNames = (environment.selectedRepos || [])
    .map((repo) => repo?.trim())
    .filter((repo): repo is string => Boolean(repo));

  if (repoFullNames.length === 0) {
    throw new Error("This environment has no repositories configured");
  }

  const repoManager = RepositoryManager.getInstance();
  const repoWorktrees: PreparedEnvironmentWorkspace["repoWorktrees"] = [];
  let projectsRoot: string | null = null;

  for (const repoFullName of repoFullNames) {
    const repoUrl = repoFullName.startsWith("http")
      ? repoFullName
      : `https://github.com/${repoFullName}.git`;

    const projectPaths = await getProjectPaths(repoUrl, teamSlugOrId);
    await fs.mkdir(projectPaths.projectPath, { recursive: true });
    await fs.mkdir(projectPaths.worktreesPath, { recursive: true });

    await repoManager.ensureRepository(repoUrl, projectPaths.originPath);

    let branch = await repoManager.getDefaultBranch(projectPaths.originPath);
    if (!branch) {
      branch = "main";
      serverLogger.warn(
        `Falling back to branch "${branch}" for ${repoFullName} (default not detected)`
      );
    }

    const worktreeInfo = await getWorktreePath({ repoUrl, branch }, teamSlugOrId);
    const workspaceResult = await setupProjectWorkspace({
      repoUrl,
      branch,
      worktreeInfo,
    });

    if (!workspaceResult.success || !workspaceResult.worktreePath) {
      throw new Error(
        workspaceResult.error ||
          `Failed to prepare workspace for ${repoFullName}`
      );
    }

    repoWorktrees.push({
      repoFullName,
      repoUrl,
      worktreePath: workspaceResult.worktreePath,
      branch,
    });

    if (!projectsRoot) {
      projectsRoot = projectPaths.projectsPath;
    }
  }

  const [primaryWorktree] = repoWorktrees;
  if (!primaryWorktree) {
    throw new Error("Failed to prepare any repositories for environment");
  }

  return {
    targetPath: primaryWorktree.worktreePath,
    projectsRoot: projectsRoot ?? path.dirname(primaryWorktree.worktreePath),
    repoWorktrees,
    environmentName: environment.name,
  };
}
