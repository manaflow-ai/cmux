import { parseArgs } from "node:util";
import * as path from "node:path";
import { promises as fs } from "node:fs";
import * as os from "node:os";
import { execSync } from "node:child_process";
import { claudeCodeCapturePRScreenshots } from "./claudeScreenshotCollector";

/**
 * Parse PR URL to extract owner, repo, and PR number
 */
function parsePRUrl(prUrl: string): {
  owner: string;
  repo: string;
  prNumber: string;
} | null {
  // Match patterns like:
  // https://github.com/owner/repo/pull/123
  // github.com/owner/repo/pull/123
  const match = prUrl.match(
    /github\.com\/([^/]+)\/([^/]+)\/pull\/(\d+)/
  );

  if (match && match[1] && match[2] && match[3]) {
    return {
      owner: match[1],
      repo: match[2],
      prNumber: match[3],
    };
  }

  return null;
}

/**
 * Execute a command and return stdout
 */
function exec(command: string, cwd?: string): string {
  return execSync(command, {
    cwd,
    encoding: "utf-8",
    stdio: ["pipe", "pipe", "inherit"],
  }).trim();
}

/**
 * Fetch PR information using gh CLI
 */
async function fetchPRInfo(
  owner: string,
  repo: string,
  prNumber: string
): Promise<{
  baseBranch: string;
  headBranch: string;
  title: string;
  description: string;
}> {
  const prInfoJson = exec(
    `gh pr view ${prNumber} --repo ${owner}/${repo} --json baseRefName,headRefName,title,body`
  );

  const prInfo = JSON.parse(prInfoJson);
  return {
    baseBranch: prInfo.baseRefName,
    headBranch: prInfo.headRefName,
    title: prInfo.title,
    description: prInfo.body || "",
  };
}

/**
 * Get changed files in PR
 */
async function getChangedFiles(
  owner: string,
  repo: string,
  prNumber: string
): Promise<string[]> {
  const filesOutput = exec(
    `gh pr view ${prNumber} --repo ${owner}/${repo} --json files --jq '.files[].path'`
  );

  return filesOutput
    .split("\n")
    .map((line) => line.trim())
    .filter((line) => line.length > 0);
}

/**
 * Set up git repository in temp directory
 */
async function setupGitRepo(
  owner: string,
  repo: string,
  prNumber: string
): Promise<{ workspaceDir: string; cleanup: () => Promise<void> }> {
  // Create temp directory
  const tempDir = await fs.mkdtemp(path.join(os.tmpdir(), "cmux-pr-"));
  const workspaceDir = path.join(tempDir, repo);

  console.log(`📁 Created temp directory: ${tempDir}`);

  try {
    // Clone the repository (shallow clone for speed)
    console.log(`📥 Cloning ${owner}/${repo}...`);
    exec(
      `git clone --depth 1 https://github.com/${owner}/${repo}.git ${repo}`,
      tempDir
    );

    // Fetch and checkout the PR branch manually (gh pr checkout doesn't work well with shallow clones)
    console.log(`🔀 Fetching PR #${prNumber}...`);
    const prBranchInfo = exec(
      `gh pr view ${prNumber} --repo ${owner}/${repo} --json headRefName --jq '.headRefName'`
    );
    const prBranch = prBranchInfo.trim();

    console.log(`🔀 Checking out branch: ${prBranch}...`);
    exec(`git fetch --depth 1 origin ${prBranch}`, workspaceDir);
    exec(`git checkout -b ${prBranch} FETCH_HEAD`, workspaceDir);

    // Copy .env file from current directory if it exists
    const currentDirEnvPath = path.join(process.cwd(), ".env");
    try {
      await fs.access(currentDirEnvPath);
      const targetEnvPath = path.join(workspaceDir, ".env");
      await fs.copyFile(currentDirEnvPath, targetEnvPath);
      console.log(`📋 Copied .env file to workspace`);
    } catch {
      // .env file doesn't exist in current directory, skip silently
    }

    console.log(`✓ Repository set up at ${workspaceDir}`);

    const cleanup = async () => {
      console.log(`🗑️  Cleaning up temp directory: ${tempDir}`);
      await fs.rm(tempDir, { recursive: true, force: true });
    };

    return { workspaceDir, cleanup };
  } catch (error) {
    // Clean up on error
    await fs.rm(tempDir, { recursive: true, force: true });
    throw error;
  }
}

/**
 * CLI entry point for capturing PR screenshots
 */
async function main() {
  let cleanupFn: (() => Promise<void>) | null = null;

  // Handle Ctrl+C and process termination
  const handleExit = async (signal: string) => {
    console.log(`\n⚠️  Received ${signal}, cleaning up...`);
    if (cleanupFn) {
      await cleanupFn();
    }
    process.exit(signal === "SIGINT" ? 130 : 143);
  };

  process.on("SIGINT", () => handleExit("SIGINT"));
  process.on("SIGTERM", () => handleExit("SIGTERM"));

  try {
    const { values } = parseArgs({
      options: {
        pr: {
          type: "string",
          short: "p",
        },
        "api-key": {
          type: "string",
        },
        output: {
          type: "string",
          short: "o",
        },
      },
    });

    if (!values.pr) {
      console.error("Error: --pr argument is required");
      console.error("Usage: --pr <PR_URL_or_NUMBER>");
      console.error("Example: --pr https://github.com/owner/repo/pull/123");
      console.error("Example: --pr 123 (uses current repo)");
      process.exit(1);
    }

    const apiKey = values["api-key"] || process.env.ANTHROPIC_API_KEY;

    if (!apiKey) {
      console.error("Error: ANTHROPIC_API_KEY is required");
      console.error(
        "Set it via --api-key flag or ANTHROPIC_API_KEY environment variable"
      );
      process.exit(1);
    }

    let owner: string;
    let repo: string;
    let prNumber: string;

    // Parse PR URL or number
    const parsed = parsePRUrl(values.pr);
    if (parsed) {
      owner = parsed.owner;
      repo = parsed.repo;
      prNumber = parsed.prNumber;
    } else if (/^\d+$/.test(values.pr)) {
      // Just a number, try to get repo from current directory
      prNumber = values.pr;
      try {
        const remoteUrl = exec("git config --get remote.origin.url");
        const match = remoteUrl.match(/github\.com[/:]([^/]+)\/([^/.]+)/);
        if (!match || !match[1] || !match[2]) {
          throw new Error("Could not parse git remote URL");
        }
        owner = match[1];
        repo = match[2];
      } catch {
        console.error(
          "Error: Could not determine repository from current directory"
        );
        console.error("Please provide full PR URL instead");
        process.exit(1);
      }
    } else {
      console.error("Error: Invalid PR format");
      console.error("Use full URL or just PR number");
      process.exit(1);
    }

    console.log(`📋 Fetching PR #${prNumber} from ${owner}/${repo}...`);

    // Fetch PR info
    const prInfo = await fetchPRInfo(owner, repo, prNumber);
    console.log(`📝 PR: ${prInfo.title}`);
    console.log(`🔀 ${prInfo.baseBranch} <- ${prInfo.headBranch}`);

    // Get changed files
    const changedFiles = await getChangedFiles(owner, repo, prNumber);
    console.log(`📄 Found ${changedFiles.length} changed files`);

    // Set up git repository
    const { workspaceDir, cleanup } = await setupGitRepo(
      owner,
      repo,
      prNumber
    );

    // Store cleanup function for signal handlers
    cleanupFn = cleanup;

    try {
      // Determine output directory
      const outputDir =
        values.output ||
        path.join(workspaceDir, ".cmux", "screenshots", `pr-${prNumber}`);

      console.log(`📸 Starting screenshot capture...`);

      // Capture screenshots
      const result = await claudeCodeCapturePRScreenshots({
        workspaceDir,
        changedFiles,
        prTitle: prInfo.title,
        prDescription: prInfo.description,
        baseBranch: prInfo.baseBranch,
        headBranch: prInfo.headBranch,
        outputDir,
        auth: { anthropicApiKey: apiKey },
    });

    if (result.status === "completed") {
      console.log("✓ Screenshots captured successfully");
      const screenshots = result.screenshots ?? [];
      console.log(`  Screenshots: ${screenshots.length}`);
      const firstScreenshot = screenshots[0]?.path;
      if (firstScreenshot) {
        console.log(`  Location: ${path.dirname(firstScreenshot)}`);
      }
      process.exit(0);
    } else if (result.status === "skipped") {
        console.log(`⊘ Skipped: ${result.reason}`);
        process.exit(0);
      } else {
        console.error(`✗ Failed: ${result.error}`);
        process.exit(1);
      }
    } finally {
      // Clean up temp directory
      await cleanup();
      cleanupFn = null;
    }
  } catch (error) {
    console.error(
      "Fatal error:",
      error instanceof Error ? error.message : String(error)
    );
    if (cleanupFn) {
      await cleanupFn();
    }
    process.exit(1);
  }
}

// Run if executed directly
if (import.meta.url === `file://${process.argv[1]}`) {
  main();
}
