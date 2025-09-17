import { exec as execCb } from "node:child_process";
import * as fs from "node:fs/promises";
import { tmpdir } from "node:os";
import * as path from "node:path";
import { promisify } from "node:util";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { RepositoryManager } from "./repositoryManager.js";

const exec = promisify(execCb);

interface RepoCase {
  url: string;
  defaultBranch: string;
}

const REPOS: RepoCase[] = [
  { url: "https://github.com/sindresorhus/is.git", defaultBranch: "main" },
  { url: "https://github.com/tj/commander.js.git", defaultBranch: "master" },
  { url: "https://github.com/stack-auth/stack-auth.git", defaultBranch: "dev" },
];

const TEST_BASE = path.join(tmpdir(), `cmux-repo-tests-${Date.now()}`);

async function gitDirExists(dir: string): Promise<boolean> {
  try {
    await fs.access(path.join(dir, ".git"));
    return true;
  } catch {
    return false;
  }
}

async function getHeadBranch(cwd: string): Promise<string> {
  const { stdout } = await exec("git rev-parse --abbrev-ref HEAD", { cwd });
  return stdout.trim();
}

async function getRemoteFetchSpecs(cwd: string): Promise<string[]> {
  const { stdout } = await exec(
    "git config --get-all remote.origin.fetch",
    { cwd }
  );
  return stdout
    .split("\n")
    .map((line) => line.trim())
    .filter((line) => line.length > 0);
}

describe.sequential("RepositoryManager branch behavior (no fallbacks)", () => {
  beforeAll(async () => {
    try {
      const { stdout } = await exec("which git");
      const gitPath = stdout.trim();
      if (gitPath) process.env.GIT_PATH = gitPath;
    } catch {
      process.env.GIT_PATH = "git";
    }
    await fs.mkdir(TEST_BASE, { recursive: true });
  });

  afterAll(async () => {
    // Best-effort cleanup: remove any worktrees first, then delete base dir
    try {
      const entries = await fs.readdir(TEST_BASE);
      for (const entry of entries) {
        const projectPath = path.join(TEST_BASE, entry);
        const originPath = path.join(projectPath, "origin");
        try {
          // List worktrees and force-remove
          const { stdout } = await exec("git worktree list --porcelain", {
            cwd: originPath,
          });
          const matches = Array.from(
            stdout.matchAll(/^worktree\s+(.*)$/gm)
          ).map((m) => m[1]);
          for (const wt of matches) {
            if (path.resolve(wt).startsWith(path.resolve(projectPath))) {
              await exec(`git worktree remove --force "${wt}"`, {
                cwd: originPath,
              }).catch(() => {});
            }
          }
        } catch {
          // ignore
        }
      }
    } catch {
      // ignore
    } finally {
      await fs.rm(TEST_BASE, { recursive: true, force: true }).catch(() => {});
    }
  });

  it("clones and checks out specified existing branches", async () => {
    const mgr = RepositoryManager.getInstance({ fetchDepth: 1 });

    for (const repo of REPOS) {
      const projectDir = path.join(
        TEST_BASE,
        repo.url
          .split("/")
          .pop()!
          .replace(/\.git$/, "")
      );
      const originPath = path.join(projectDir, "origin");
      await fs.mkdir(projectDir, { recursive: true });

      await mgr.ensureRepository(repo.url, originPath, repo.defaultBranch);

      expect(await gitDirExists(originPath)).toBe(true);
      expect(await getHeadBranch(originPath)).toBe(repo.defaultBranch);
      const fetchSpecs = await getRemoteFetchSpecs(originPath);
      expect(fetchSpecs).toContain(
        "+refs/heads/*:refs/remotes/origin/*"
      );
    }
  }, 120_000);

  it("throws when switching to a non-existent branch", async () => {
    const mgr = RepositoryManager.getInstance({ fetchDepth: 1 });
    const repo = REPOS[0]; // use a stable repo
    const projectDir = path.join(TEST_BASE, "non-existent-branch");
    const originPath = path.join(projectDir, "origin");
    await fs.mkdir(projectDir, { recursive: true });

    // First ensure repo exists on a valid branch
    await mgr.ensureRepository(repo.url, originPath, repo.defaultBranch);

    // Now request a non-existent branch – should reject
    await expect(
      mgr.ensureRepository(repo.url, originPath, "this-branch-should-not-exist")
    ).rejects.toBeTruthy();
  }, 90_000);

  it("creates worktrees from a valid base and errors for missing base", async () => {
    const mgr = RepositoryManager.getInstance({ fetchDepth: 1 });
    const repo = REPOS[2]; // stack-auth with dev default
    const projectDir = path.join(TEST_BASE, "worktree-tests");
    const originPath = path.join(projectDir, "origin");
    await fs.mkdir(projectDir, { recursive: true });

    await mgr.ensureRepository(repo.url, originPath, repo.defaultBranch);

    const okWorktree = path.join(projectDir, "worktrees", "ok-branch");
    await fs.mkdir(path.dirname(okWorktree), { recursive: true });
    await mgr.createWorktree(
      originPath,
      okWorktree,
      "cmux-ok",
      repo.defaultBranch
    );
    // Worktree path directory should exist now
    const exists = await fs
      .access(okWorktree)
      .then(() => true)
      .catch(() => false);
    expect(exists).toBe(true);

    const badWorktree = path.join(projectDir, "worktrees", "bad-branch");
    await expect(
      mgr.createWorktree(
        originPath,
        badWorktree,
        "cmux-bad",
        "this-branch-should-not-exist"
      )
    ).rejects.toThrow(
      /Base branch 'origin\/this-branch-should-not-exist' not found/i
    );
  }, 120_000);

  it("handles non-default 'main' branch for stack-auth and can create worktree from it", async () => {
    const mgr = RepositoryManager.getInstance({ fetchDepth: 1 });
    const repo = REPOS.find((r) =>
      r.url.includes("stack-auth/stack-auth.git")
    )!;
    const projectDir = path.join(TEST_BASE, "stack-auth-main-case");
    const originPath = path.join(projectDir, "origin");
    await fs.mkdir(projectDir, { recursive: true });

    // Ensure directly on 'main' (not default)
    await mgr.ensureRepository(repo.url, originPath, "main");
    expect(await getHeadBranch(originPath)).toBe("main");

    // Create a worktree based on main
    const wt = path.join(projectDir, "worktrees", "from-main");
    await fs.mkdir(path.dirname(wt), { recursive: true });
    await mgr.createWorktree(originPath, wt, "cmux-from-main", "main");
    const exists = await fs
      .access(wt)
      .then(() => true)
      .catch(() => false);
    expect(exists).toBe(true);
  }, 120_000);

  it("detects remote default branches when no branch specified", async () => {
    const mgr = RepositoryManager.getInstance({ fetchDepth: 1 });

    for (const repo of REPOS) {
      const projectDir = path.join(
        TEST_BASE,
        `default-branch-${repo.defaultBranch}-${repo.url
          .split("/")
          .pop()!
          .replace(/\.git$/, "")}`
      );
      const originPath = path.join(projectDir, "origin");
      await fs.mkdir(projectDir, { recursive: true });

      await mgr.ensureRepository(repo.url, originPath);
      const detected = await mgr.getDefaultBranch(originPath);
      expect([repo.defaultBranch, "develop"]).toContain(detected);
    }
  }, 120_000);

  it("force-updates remote-tracking ref on non-fast-forward remote rewrite", async () => {
    // This test sets up a local bare repo as the remote, clones it via RepositoryManager,
    // then rewrites the remote's main branch to an unrelated commit and ensures that a
    // subsequent ensureRepository() call updates origin/main despite the non-FF change.
    const mgr = RepositoryManager.getInstance({ fetchDepth: 1 });

    const projectDir = path.join(TEST_BASE, "non-ff-rewrite");
    const originPath = path.join(projectDir, "origin");
    const dev1Path = path.join(projectDir, "dev1");
    const dev2Path = path.join(projectDir, "dev2");
    const barePath = path.join(projectDir, "remote.git");

    await fs.mkdir(projectDir, { recursive: true });

    // Init bare remote
    await exec(`git init --bare "${barePath}"`);

    // First history (commit A)
    await fs.mkdir(dev1Path, { recursive: true });
    await exec(`git init -b main`, { cwd: dev1Path });
    await exec(`git config user.email test@example.com`, { cwd: dev1Path });
    await exec(`git config user.name test`, { cwd: dev1Path });
    await fs.writeFile(path.join(dev1Path, "a.txt"), "A\n");
    await exec(`git add .`, { cwd: dev1Path });
    await exec(`git commit -m A`, { cwd: dev1Path });
    await exec(`git remote add origin "${barePath}"`, { cwd: dev1Path });
    await exec(`git push -u origin main`, { cwd: dev1Path });
    const { stdout: aShaOut } = await exec(`git rev-parse refs/heads/main`, {
      cwd: dev1Path,
    });
    const aSha = aShaOut.trim();

    // Clone via RepositoryManager and land on A
    await mgr.ensureRepository(barePath, originPath, "main");
    const { stdout: head1 } = await exec(`git rev-parse HEAD`, {
      cwd: originPath,
    });
    expect(head1.trim()).toBe(aSha);

    // Rewrite remote main to unrelated commit B
    await fs.mkdir(dev2Path, { recursive: true });
    await exec(`git init -b main`, { cwd: dev2Path });
    await exec(`git config user.email test@example.com`, { cwd: dev2Path });
    await exec(`git config user.name test`, { cwd: dev2Path });
    await fs.writeFile(path.join(dev2Path, "b.txt"), "B\n");
    await exec(`git add .`, { cwd: dev2Path });
    await exec(`git commit -m B`, { cwd: dev2Path });
    await exec(`git remote add origin "${barePath}"`, { cwd: dev2Path });
    await exec(`git push -f origin main`, { cwd: dev2Path });
    const { stdout: bShaOut } = await exec(`git rev-parse refs/heads/main`, {
      cwd: dev2Path,
    });
    const bSha = bShaOut.trim();

    // Ensure again; previously this would fail on fetch non-FF; now we expect it to succeed
    await mgr.ensureRepository(barePath, originPath, "main");
    const { stdout: head2 } = await exec(`git rev-parse HEAD`, {
      cwd: originPath,
    });
    expect(head2.trim()).toBe(bSha);
  }, 120_000);
});
