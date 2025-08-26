import { execSync } from "node:child_process";
import { serverLogger } from "./fileLogger.js";

export interface GitRepoInfo {
  owner: string;
  repo: string;
  defaultBranch: string;
  currentBranch: string;
}

export async function getGitRepoInfo(cwd = "/root/workspace"): Promise<GitRepoInfo> {
  try {
    // Get remote URL
    const remoteUrl = execSync("git remote get-url origin", { cwd, encoding: "utf8" }).trim();
    
    // Parse owner and repo from URL
    // Supports both HTTPS and SSH URLs
    let owner = "";
    let repo = "";
    
    // HTTPS: https://github.com/owner/repo.git
    const httpsMatch = remoteUrl.match(/github\.com\/([^\/]+)\/([^\/]+?)(?:\.git)?$/);
    if (httpsMatch) {
      owner = httpsMatch[1];
      repo = httpsMatch[2];
    } else {
      // SSH: git@github.com:owner/repo.git
      const sshMatch = remoteUrl.match(/git@github\.com:([^\/]+)\/([^\/]+?)(?:\.git)?$/);
      if (sshMatch) {
        owner = sshMatch[1];
        repo = sshMatch[2];
      }
    }
    
    if (!owner || !repo) {
      throw new Error(`Could not parse GitHub repository from URL: ${remoteUrl}`);
    }
    
    // Get default branch
    let defaultBranch = "main";
    try {
      const symbolicRef = execSync("git symbolic-ref refs/remotes/origin/HEAD", { cwd, encoding: "utf8" }).trim();
      const branchMatch = symbolicRef.match(/refs\/remotes\/origin\/(.+)$/);
      if (branchMatch) {
        defaultBranch = branchMatch[1];
      }
    } catch {
      // Fallback to common defaults
      try {
        execSync("git show-ref --verify --quiet refs/heads/main", { cwd });
        defaultBranch = "main";
      } catch {
        try {
          execSync("git show-ref --verify --quiet refs/heads/master", { cwd });
          defaultBranch = "master";
        } catch {
          // Keep "main" as default
        }
      }
    }
    
    // Get current branch
    const currentBranch = execSync("git rev-parse --abbrev-ref HEAD", { cwd, encoding: "utf8" }).trim();
    
    return {
      owner,
      repo,
      defaultBranch,
      currentBranch,
    };
  } catch (error) {
    serverLogger.error("[GitRepoInfo] Failed to get repository info:", error);
    throw error;
  }
}

export async function getLatestCommitMessage(cwd = "/root/workspace"): Promise<{ subject: string; body: string; fullMessage: string }> {
  try {
    const subject = execSync("git log -1 --pretty=format:%s", { cwd, encoding: "utf8" }).trim();
    const body = execSync("git log -1 --pretty=format:%b", { cwd, encoding: "utf8" }).trim();
    const fullMessage = execSync("git log -1 --pretty=format:%B", { cwd, encoding: "utf8" }).trim();
    
    return {
      subject,
      body,
      fullMessage,
    };
  } catch (error) {
    serverLogger.error("[GitRepoInfo] Failed to get latest commit message:", error);
    return {
      subject: "",
      body: "",
      fullMessage: "",
    };
  }
}