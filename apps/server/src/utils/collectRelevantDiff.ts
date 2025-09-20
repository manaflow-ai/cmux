import { execFile } from "node:child_process";
import type { ExecFileOptions } from "node:child_process";
import { mkdtemp, rm, stat } from "node:fs/promises";
import path from "node:path";
import { tmpdir } from "node:os";

const DEFAULT_MAX_SIZE_BYTES = 200_000;

type GitEnv = NodeJS.ProcessEnv;

interface GitRunOptions {
  cwd: string;
  env: GitEnv;
  allowFailure?: boolean;
  maxBuffer?: number;
}

interface GitRunResult {
  stdout: string;
  stderr: string;
  success: boolean;
  code: number | null;
}

interface CollectRelevantDiffOptions {
  repoPath: string;
  /**
   * Optional ref to diff against, e.g. "origin/main".
   * Falls back to auto-detected default branch when omitted.
   */
  baseRef?: string;
  /** Override maximum file size considered relevant (defaults to 200kb). */
  maxSizeBytes?: number;
}

const execFilePromise = async (
  file: string,
  args: string[],
  options: ExecFileOptions & { allowFailure?: boolean }
): Promise<GitRunResult> => {
  const { allowFailure, ...execOptions } = options;
  return new Promise<GitRunResult>((resolve, reject) => {
    execFile(
      file,
      args,
      {
        ...execOptions,
        encoding: "utf8",
      },
      (error, stdout, stderr) => {
        if (error) {
          if (allowFailure) {
            const nodeError = error as NodeJS.ErrnoException & {
              code?: number;
            };
            const rawCode = nodeError.code;
            const code = typeof rawCode === "number" ? rawCode : null;
            resolve({
              stdout: stdout ?? "",
              stderr: stderr ?? "",
              success: false,
              code,
            });
            return;
          }
          reject(error);
          return;
        }

        resolve({
          stdout: stdout ?? "",
          stderr: stderr ?? "",
          success: true,
          code: 0,
        });
      }
    );
  });
};

const createGitEnv = (env?: GitEnv): GitEnv => ({
  ...process.env,
  GIT_PAGER: "cat",
  PAGER: "cat",
  ...(env ?? {}),
});

const normalizePath = (input: string): string =>
  input.replace(/\\/g, "/").replace(/^\.\//, "");

const EXACT_MATCHES = new Set([
  ".git",
  "pnpm-lock.yaml",
  "yarn.lock",
  "package-lock.json",
  "Pipfile.lock",
  "poetry.lock",
  "Gemfile.lock",
  "composer.lock",
  "Cargo.lock",
  ".DS_Store",
]);

const PREFIX_MATCHES = [
  ".git/",
  "node_modules/",
  "dist/",
  "build/",
  ".next/",
  "out/",
  ".turbo/",
  "venv/",
  ".venv/",
  "__pycache__/",
  "vendor/",
  "target/",
  "coverage/",
  ".nyc_output/",
  ".cache/",
  "coverage-",
];

const EXT_MATCHES = new Set([
  ".png",
  ".jpg",
  ".jpeg",
  ".gif",
  ".svg",
  ".ico",
  ".webp",
  ".bmp",
  ".pdf",
  ".zip",
  ".tar",
  ".gz",
  ".tgz",
  ".xz",
  ".bz2",
  ".7z",
  ".mp4",
  ".mp3",
  ".avi",
  ".log",
  ".tmp",
  ".cache",
  ".map",
]);

const SUFFIX_MATCHES = [".min.js", ".min.css"];

const isIgnoredPath = (rawPath: string): boolean => {
  const normalized = normalizePath(rawPath);
  if (!normalized) return false;

  if (EXACT_MATCHES.has(normalized)) return true;

  for (const prefix of PREFIX_MATCHES) {
    if (normalized.startsWith(prefix)) {
      return true;
    }
  }

  for (const suffix of SUFFIX_MATCHES) {
    if (normalized.endsWith(suffix)) {
      return true;
    }
  }

  const ext = path.extname(normalized).toLowerCase();
  if (ext && EXT_MATCHES.has(ext)) {
    return true;
  }

  return false;
};

const runGit = async (
  args: string[],
  options: GitRunOptions
): Promise<GitRunResult> => {
  const { cwd, env, allowFailure, maxBuffer } = options;
  return execFilePromise("git", args, {
    cwd,
    env,
    maxBuffer: maxBuffer ?? 12 * 1024 * 1024,
    allowFailure,
  });
};

const parsePaths = (input: string): string[] =>
  input
    .split("\n")
    .map((line) => line.trim())
    .filter((line) => line.length > 0);

const parseSize = (value: string): number => {
  const trimmed = value.trim();
  if (!trimmed) return 0;
  const parsed = Number.parseInt(trimmed, 10);
  return Number.isFinite(parsed) && !Number.isNaN(parsed) ? parsed : 0;
};

const getSizeFromCommit = async (
  repoRoot: string,
  env: GitEnv,
  ref: string,
  filePath: string
): Promise<number | null> => {
  const existence = await runGit(["cat-file", "-e", `${ref}:${filePath}`], {
    cwd: repoRoot,
    env,
    allowFailure: true,
  });

  if (!existence.success) {
    return null;
  }

  const sizeResult = await runGit(["cat-file", "-s", `${ref}:${filePath}`], {
    cwd: repoRoot,
    env,
    allowFailure: true,
  });

  return parseSize(sizeResult.stdout);
};

const getWorkingTreeSize = async (
  repoRoot: string,
  filePath: string
): Promise<number | null> => {
  try {
    const stats = await stat(path.join(repoRoot, filePath));
    return stats.isFile() ? stats.size : null;
  } catch {
    return null;
  }
};

type SizeStrategy = "working-or-base" | "head-or-base";

const filterPaths = async (
  repoRoot: string,
  env: GitEnv,
  filePaths: string[],
  mergeBase: string | null,
  maxSizeBytes: number,
  strategy: SizeStrategy
): Promise<string[]> => {
  const filtered: string[] = [];

  for (const rawPath of filePaths) {
    if (isIgnoredPath(rawPath)) continue;
    let size: number | null = null;

    if (strategy === "working-or-base") {
      size = await getWorkingTreeSize(repoRoot, rawPath);
      if (size == null && mergeBase) {
        size = await getSizeFromCommit(repoRoot, env, mergeBase, rawPath);
      }
    } else {
      size = await getSizeFromCommit(repoRoot, env, "HEAD", rawPath);
      if (size == null && mergeBase) {
        size = await getSizeFromCommit(repoRoot, env, mergeBase, rawPath);
      }
    }

    const resolvedSize = size ?? 0;
    if (resolvedSize > maxSizeBytes) continue;

    filtered.push(rawPath);
  }

  return filtered;
};

const determineBaseRef = async (
  repoRoot: string,
  env: GitEnv,
  explicit?: string
): Promise<string | null> => {
  const override = explicit?.trim() || process.env.CMUX_DIFF_BASE?.trim();
  if (override) {
    return override;
  }

  const gitDir = await runGit(["rev-parse", "--git-dir"], {
    cwd: repoRoot,
    env,
    allowFailure: true,
  });
  if (!gitDir.success) {
    return null;
  }

  const remote = await runGit(["remote", "get-url", "origin"], {
    cwd: repoRoot,
    env,
    allowFailure: true,
  });
  if (!remote.success) {
    return null;
  }

  await runGit(["fetch", "--quiet", "--prune", "origin"], {
    cwd: repoRoot,
    env,
    allowFailure: true,
  });

  const originHead = await runGit(
    ["symbolic-ref", "--quiet", "--short", "refs/remotes/origin/HEAD"],
    {
      cwd: repoRoot,
      env,
      allowFailure: true,
    }
  );
  if (originHead.success) {
    const ref = originHead.stdout.trim();
    if (ref) {
      return ref;
    }
  }

  const candidates = ["origin/main", "origin/master"];
  for (const candidate of candidates) {
    const exists = await runGit(["rev-parse", "--verify", candidate], {
      cwd: repoRoot,
      env,
      allowFailure: true,
    });
    if (exists.success) {
      return candidate;
    }
  }

  return null;
};

const collectWithBase = async (
  repoRoot: string,
  env: GitEnv,
  baseRef: string,
  maxSizeBytes: number
): Promise<string> => {
  const mergeBaseResult = await runGit(["merge-base", baseRef, "HEAD"], {
    cwd: repoRoot,
    env,
    allowFailure: true,
  });
  const mergeBase = mergeBaseResult.stdout.trim();

  if (!mergeBase) {
    throw new Error("Could not determine merge-base");
  }

  const status = await runGit(["status", "--porcelain"], {
    cwd: repoRoot,
    env,
    allowFailure: true,
  });
  const hasUncommitted = status.stdout.trim().length > 0;

  if (hasUncommitted) {
    const tracked = await runGit(
      ["--no-pager", "diff", "--name-only", mergeBase],
      {
        cwd: repoRoot,
        env,
        allowFailure: true,
      }
    );
    const untracked = await runGit(
      ["ls-files", "--others", "--exclude-standard"],
      {
        cwd: repoRoot,
        env,
        allowFailure: true,
      }
    );

    const trackedFiles = parsePaths(tracked.stdout);
    const untrackedFiles = parsePaths(untracked.stdout);

    const filteredTracked = await filterPaths(
      repoRoot,
      env,
      trackedFiles,
      mergeBase,
      maxSizeBytes,
      "working-or-base"
    );
    const filteredUntracked = await filterPaths(
      repoRoot,
      env,
      untrackedFiles,
      mergeBase,
      maxSizeBytes,
      "working-or-base"
    );

    const filtered = Array.from(
      new Set([...filteredTracked, ...filteredUntracked])
    );
    if (filtered.length === 0) {
      return "";
    }

    const tmpDir = await mkdtemp(path.join(tmpdir(), "cmux-diff-index-"));
    const indexPath = path.join(tmpDir, "index");
    const indexEnv = { ...env, GIT_INDEX_FILE: indexPath };

    try {
      await runGit(["read-tree", "HEAD"], {
        cwd: repoRoot,
        env: indexEnv,
        allowFailure: true,
      });

      for (const filePath of filtered) {
        const absolute = path.join(repoRoot, filePath);
        let exists = false;
        try {
          const fileStat = await stat(absolute);
          exists = fileStat.isFile();
        } catch {
          exists = false;
        }
        if (!exists) continue;
        await runGit(["add", "--", filePath], {
          cwd: repoRoot,
          env: indexEnv,
          allowFailure: true,
        });
      }

      const diff = await runGit(
        ["--no-pager", "diff", "--staged", "-M", "--no-color", mergeBase],
        {
          cwd: repoRoot,
          env: indexEnv,
          allowFailure: true,
          maxBuffer: 12 * 1024 * 1024,
        }
      );

      return diff.stdout.trim();
    } finally {
      await rm(tmpDir, { recursive: true, force: true });
    }
  }

  const changed = await runGit(
    ["--no-pager", "diff", "--name-only", mergeBase, "HEAD"],
    {
      cwd: repoRoot,
      env,
      allowFailure: true,
    }
  );
  const files = parsePaths(changed.stdout);
  const filteredList = await filterPaths(
    repoRoot,
    env,
    files,
    mergeBase,
    maxSizeBytes,
    "head-or-base"
  );

  const filtered = Array.from(new Set(filteredList));

  if (filtered.length === 0) {
    return "";
  }

  const diff = await runGit(
    [
      "--no-pager",
      "diff",
      "-M",
      "--no-color",
      mergeBase,
      "HEAD",
      "--",
      ...filtered,
    ],
    {
      cwd: repoRoot,
      env,
      allowFailure: true,
      maxBuffer: 12 * 1024 * 1024,
    }
  );

  return diff.stdout.trim();
};

const collectWithoutBase = async (
  repoRoot: string,
  env: GitEnv,
  maxSizeBytes: number
): Promise<string> => {
  const tracked = await runGit(["--no-pager", "diff", "--name-only"], {
    cwd: repoRoot,
    env,
    allowFailure: true,
  });
  const staged = await runGit(
    ["--no-pager", "diff", "--name-only", "--cached"],
    {
      cwd: repoRoot,
      env,
      allowFailure: true,
    }
  );
  const untracked = await runGit(
    ["ls-files", "--others", "--exclude-standard"],
    {
      cwd: repoRoot,
      env,
      allowFailure: true,
    }
  );

  const combined = new Set<string>();
  for (const item of [tracked, staged, untracked].flatMap((res) =>
    parsePaths(res.stdout)
  )) {
    if (!combined.has(item)) {
      combined.add(item);
    }
  }

  const tmpDir = await mkdtemp(path.join(tmpdir(), "cmux-diff-index-"));
  const indexPath = path.join(tmpDir, "index");
  const indexEnv = { ...env, GIT_INDEX_FILE: indexPath };

  try {
    for (const filePath of combined) {
      if (isIgnoredPath(filePath)) continue;
      const size = await getWorkingTreeSize(repoRoot, filePath);
      const resolvedSize = size ?? 0;
      if (resolvedSize > maxSizeBytes) continue;

      if (size != null) {
        await runGit(["add", "--", filePath], {
          cwd: repoRoot,
          env: indexEnv,
          allowFailure: true,
        });
      }
    }

    const deletedDiff = await runGit(
      ["--no-pager", "diff", "--name-only", "--diff-filter=D"],
      {
        cwd: repoRoot,
        env,
        allowFailure: true,
      }
    );
    const deletedFiles = new Set<string>(parsePaths(deletedDiff.stdout));
    const lsDeleted = await runGit(["ls-files", "--deleted"], {
      cwd: repoRoot,
      env,
      allowFailure: true,
    });
    for (const filePath of parsePaths(lsDeleted.stdout)) {
      deletedFiles.add(filePath);
    }

    for (const filePath of deletedFiles) {
      if (isIgnoredPath(filePath)) continue;
      await runGit(["update-index", "--remove", "--", filePath], {
        cwd: repoRoot,
        env: indexEnv,
        allowFailure: true,
      });
    }

    const diff = await runGit(
      ["--no-pager", "diff", "--staged", "--no-color"],
      {
        cwd: repoRoot,
        env: indexEnv,
        allowFailure: true,
        maxBuffer: 12 * 1024 * 1024,
      }
    );

    return diff.stdout.trim();
  } finally {
    await rm(tmpDir, { recursive: true, force: true });
  }
};

export async function collectRelevantDiff(
  options: CollectRelevantDiffOptions
): Promise<string> {
  const { repoPath, baseRef, maxSizeBytes } = options;
  const env = createGitEnv();

  const repoRootResult = await runGit(["rev-parse", "--show-toplevel"], {
    cwd: repoPath,
    env,
    allowFailure: true,
  });

  const repoRoot = repoRootResult.stdout.trim();
  if (!repoRoot) {
    throw new Error("Not a git repository");
  }

  const limit = Number.isFinite(maxSizeBytes ?? NaN)
    ? (maxSizeBytes as number)
    : DEFAULT_MAX_SIZE_BYTES;

  const resolvedBase = await determineBaseRef(repoRoot, env, baseRef);
  if (resolvedBase) {
    try {
      return await collectWithBase(repoRoot, env, resolvedBase, limit);
    } catch {
      // Fall back to working tree diff if merge-base computation fails.
    }
  }

  return collectWithoutBase(repoRoot, env, limit);
}
