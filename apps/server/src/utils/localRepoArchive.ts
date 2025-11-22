import { execFile } from "node:child_process";
import { promises as fs } from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import { promisify } from "node:util";
import { serverLogger } from "./fileLogger";

const execFileAsync = promisify(execFile);

const expandHome = (input: string): string => {
  if (!input.startsWith("~")) {
    return input;
  }
  const home = os.homedir();
  return path.join(home, input.slice(1));
};

export interface LocalRepoArchiveInfo {
  archivePath: string;
  base64Data?: string;
  repoName: string;
  repoRoot: string;
  headSha: string;
  branchName: string;
  tempDir: string;
}

export async function createLocalRepoArchive(
  sourcePath: string,
  opts: { includeBase64?: boolean } = {}
): Promise<LocalRepoArchiveInfo> {
  const expanded = expandHome(sourcePath);
  const resolved = path.resolve(expanded);
  const repoRoot = await resolveGitRoot(resolved);
  await verifyGitHead(repoRoot);
  const branchName = (await getGitOutput(repoRoot, ["rev-parse", "--abbrev-ref", "HEAD"])) || "main";
  const headSha = await getGitOutput(repoRoot, ["rev-parse", "HEAD"]);
  const tempDir = await fs.mkdtemp(path.join(os.tmpdir(), "cmux-archive-"));
  const archivePath = path.join(tempDir, "repo.tar");

  await execFileAsync("git", [
    "-C",
    repoRoot,
    "archive",
    "--format=tar",
    "--output",
    archivePath,
    "HEAD",
  ]);

  let base64Data: string | undefined;
  if (opts.includeBase64) {
    const buffer = await fs.readFile(archivePath);
    base64Data = buffer.toString("base64");
  }

  const repoName = path.basename(repoRoot);
  serverLogger.info(
    `[localRepoArchive] Created archive for ${repoName} at ${archivePath}`
  );

  return {
    archivePath,
    base64Data,
    repoName,
    repoRoot,
    headSha,
    branchName,
    tempDir,
  };
}

export async function cleanupLocalRepoArchive(
  info: LocalRepoArchiveInfo
): Promise<void> {
  await fs.rm(info.tempDir, { recursive: true, force: true }).catch(() => {});
}

export async function extractArchiveToWorkspace(
  archivePath: string,
  destination: string,
  branchName: string
): Promise<void> {
  await fs.rm(destination, { recursive: true, force: true }).catch(() => {});
  await fs.mkdir(destination, { recursive: true });
  await execFileAsync("tar", ["-xf", archivePath, "-C", destination]);
  await execFileAsync("git", ["init"], { cwd: destination });
  await execFileAsync("git", ["checkout", "-b", branchName], {
    cwd: destination,
  });
  await execFileAsync("git", ["config", "user.name", "cmux-local"], {
    cwd: destination,
  });
  await execFileAsync("git", ["config", "user.email", "local@cmux.dev"], {
    cwd: destination,
  });
  await execFileAsync("git", ["add", "--all"], { cwd: destination });
  await execFileAsync(
    "git",
    ["commit", "--allow-empty", "-m", "Initial snapshot from local archive"],
    { cwd: destination }
  );
}

async function resolveGitRoot(target: string): Promise<string> {
  const { stdout } = await execFileAsync("git", [
    "-C",
    target,
    "rev-parse",
    "--show-toplevel",
  ]);
  const repoRoot = stdout.trim();
  if (!repoRoot) {
    throw new Error(`Failed to resolve git repository for ${target}`);
  }
  return repoRoot;
}

async function verifyGitHead(target: string): Promise<void> {
  await execFileAsync("git", ["-C", target, "rev-parse", "--verify", "HEAD"]);
}

async function getGitOutput(
  target: string,
  args: string[]
): Promise<string> {
  const { stdout } = await execFileAsync("git", ["-C", target, ...args]);
  return stdout.trim();
}
