import { promises as fs } from "node:fs";
import * as path from "node:path";

import { log } from "../logger";
import { runCommandCapture, WORKSPACE_ROOT } from "../crown/utils";
import { filterTextFiles, parseFileList, resolveMergeBase } from "./git";
import {
  SCREENSHOT_COLLECTOR_DIRECTORY_URL,
  SCREENSHOT_COLLECTOR_LOG_PATH,
  logToScreenshotCollector,
} from "./logger";
import { detectGitRepoPath, listGitRepoPaths } from "../crown/git";
import { readPrDescription } from "./context";
import { loadScreenshotCollector, type ScreenshotCollectorModule, type ClaudeCodeAuthConfig } from "./screenshotCollectorLoader";

export interface StartScreenshotCollectionOptions {
  anthropicApiKey?: string | null;
  taskRunJwt?: string | null;
  /** Convex site URL for fetching remote screenshot collector */
  convexUrl?: string | null;
  outputPath?: string;
  prTitle?: string | null;
  prDescription?: string | null;
  headBranch?: string | null;
  baseBranch?: string | null;
  changedFiles?: string[] | null;
  /** Command to install dependencies (e.g., "bun install") */
  installCommand?: string | null;
  /** Command to start the dev server (e.g., "bun run dev") */
  devCommand?: string | null;
}

interface CapturedScreenshot {
  path: string;
  fileName: string;
  description?: string;
}

interface CapturedVideo {
  path: string;
  fileName: string;
  description?: string;
}

export type ScreenshotCollectionResult =
  | {
      status: "completed";
      screenshots: CapturedScreenshot[];
      videos: CapturedVideo[];
      commitSha: string;
      hasUiChanges?: boolean;
    }
  | {
      status: "skipped";
      reason: string;
      commitSha?: string;
      hasUiChanges?: boolean;
    }
  | {
      status: "failed";
      error: string;
      commitSha?: string;
      hasUiChanges?: boolean;
    };

function sanitizeSegment(segment: string | null | undefined): string {
  if (!segment) {
    return "current";
  }
  const normalized = segment.trim().replace(/[^A-Za-z0-9._-]/g, "-");
  return normalized.length > 0 ? normalized : "current";
}

function formatOptionalValue(value: string | null | undefined): string {
  const trimmed = value?.trim();
  return trimmed ? trimmed : "<unset>";
}

function normalizeConvexUrl(value?: string | null): string | undefined {
  if (!value) return undefined;
  const trimmed = value.trim();
  if (!trimmed) return undefined;

  try {
    const url = new URL(trimmed);
    if (url.hostname.endsWith(".convex.cloud")) {
      url.hostname = url.hostname.replace(/\.convex\.cloud$/, ".convex.site");
    }
    return url.toString().replace(/\/$/, "");
  } catch {
    return trimmed
      .replace(/\/$/, "")
      .replace(/\.convex\.cloud$/, ".convex.site");
  }
}

async function detectHeadBranch(workspaceDir: string): Promise<string | null> {
  try {
    const output = await runCommandCapture(
      "git",
      ["rev-parse", "--abbrev-ref", "HEAD"],
      { cwd: workspaceDir }
    );
    const branch = output.split("\n")[0]?.trim();
    return branch && branch.length > 0 ? branch : null;
  } catch (error) {
    log("WARN", "Failed to detect current branch for screenshots", {
      error: error instanceof Error ? error.message : String(error),
    });
    return null;
  }
}

async function resolveCommitSha(workspaceDir: string): Promise<string> {
  const raw = await runCommandCapture("git", ["rev-parse", "HEAD"], {
    cwd: workspaceDir,
  });
  const commit = raw.split("\n")[0]?.trim();
  if (!commit) {
    throw new Error("Unable to resolve HEAD commit for screenshots");
  }
  return commit;
}

function resolvePrTitle(params: {
  explicitTitle?: string | null;
  prDescription?: string | null;
  headBranch: string;
}): string {
  if (params.explicitTitle && params.explicitTitle.trim().length > 0) {
    return params.explicitTitle.trim();
  }

  if (params.prDescription) {
    const firstLine = params.prDescription
      .split(/\r?\n/)
      .map((line) => line.trim())
      .find((line) => line.length > 0);
    if (firstLine) {
      return firstLine.slice(0, 120);
    }
  }

  return `UI screenshots for ${params.headBranch}`;
}

function resolveOutputDirectory(
  headBranch: string,
  collectorModule: ScreenshotCollectorModule,
  requestedPath?: string
): { outputDir: string; copyTarget?: string } {
  const { normalizeScreenshotOutputDir, SCREENSHOT_STORAGE_ROOT } = collectorModule;

  if (requestedPath) {
    const trimmed = requestedPath.trim();
    if (trimmed.length > 0) {
      if (trimmed.endsWith(".png")) {
        const normalizedCopyTarget = normalizeScreenshotOutputDir(trimmed);
        return {
          outputDir: path.dirname(normalizedCopyTarget),
          copyTarget: normalizedCopyTarget,
        };
      }
      return { outputDir: normalizeScreenshotOutputDir(trimmed) };
    }
  }

  return {
    outputDir: path.join(
      SCREENSHOT_STORAGE_ROOT,
      `${Date.now()}-${sanitizeSegment(headBranch)}`
    ),
  };
}

export async function startScreenshotCollection(
  options: StartScreenshotCollectionOptions = {}
): Promise<ScreenshotCollectionResult> {
  await logToScreenshotCollector("start-screenshot-collection triggered");
  log("INFO", "Screenshot collection trigger recorded", {
    path: SCREENSHOT_COLLECTOR_LOG_PATH,
    openVSCodeUrl: SCREENSHOT_COLLECTOR_DIRECTORY_URL,
  });
  const normalizedConvexUrl = normalizeConvexUrl(options.convexUrl ?? undefined);
  const convexUrlLabel = formatOptionalValue(normalizedConvexUrl);
  const originalConvexUrlLabel = formatOptionalValue(options.convexUrl ?? undefined);
  if (convexUrlLabel !== originalConvexUrlLabel) {
    await logToScreenshotCollector(
      `Normalized Convex URL from ${originalConvexUrlLabel} to ${convexUrlLabel}`
    );
  }
  await logToScreenshotCollector(
    `Convex URL for screenshot collector: ${convexUrlLabel}`
  );
  if (convexUrlLabel !== "<unset>") {
    await logToScreenshotCollector(
      `Expected ANTHROPIC_BASE_URL: ${convexUrlLabel}/api/anthropic`
    );
  }

  // Load the screenshot collector module from Convex storage
  await logToScreenshotCollector("Loading screenshot collector module...");
  const collectorModule = await loadScreenshotCollector(normalizedConvexUrl);
  await logToScreenshotCollector("Screenshot collector module loaded");

  const workspaceRoot = WORKSPACE_ROOT;
  const repoCandidates: string[] = [];
  const repoCandidateSet = new Set<string>();
  const addCandidate = (candidate?: string | null) => {
    if (!candidate) {
      return;
    }
    const normalized = path.resolve(candidate);
    if (!repoCandidateSet.has(normalized)) {
      repoCandidateSet.add(normalized);
      repoCandidates.push(normalized);
    }
  };

  try {
    addCandidate(await detectGitRepoPath());
  } catch (error) {
    const message =
      error instanceof Error ? error.message : String(error ?? "unknown");
    log("WARN", "Failed to detect primary git repository for screenshots", {
      error: message,
    });
  }

  try {
    const discoveredRepos = await listGitRepoPaths();
    discoveredRepos.forEach(addCandidate);
  } catch (error) {
    const message =
      error instanceof Error ? error.message : String(error ?? "unknown");
    log("WARN", "Failed to enumerate git repositories for screenshots", {
      error: message,
    });
  }

  addCandidate(workspaceRoot);

  if (repoCandidates.length === 0) {
    const reason = `No git repositories detected within ${workspaceRoot}`;
    await logToScreenshotCollector(reason);
    log("ERROR", reason, { workspaceRoot });
    return { status: "failed", error: reason };
  }

  await logToScreenshotCollector(
    `Evaluating ${repoCandidates.length} git repo(s) for screenshots`
  );

  const repoSelectionErrors: { path: string; error: string }[] = [];
  let workspaceDir = "";
  let mergeBaseInfo: { baseBranch: string; mergeBase: string } | null = null;

  for (const candidate of repoCandidates) {
    try {
      const info = await resolveMergeBase(
        candidate,
        options.baseBranch ?? null
      );
      workspaceDir = candidate;
      mergeBaseInfo = info;
      break;
    } catch (error) {
      const message =
        error instanceof Error ? error.message : String(error ?? "unknown");
      repoSelectionErrors.push({ path: candidate, error: message });
      await logToScreenshotCollector(
        `Unable to resolve merge base in ${candidate}: ${message}`
      );
    }
  }

  if (!workspaceDir || !mergeBaseInfo) {
    const reason =
      repoSelectionErrors.length > 0
        ? `Unable to determine a merge base for any repository candidate: ${repoSelectionErrors
            .map(({ path: repoPath, error }) => `${repoPath}: ${error}`)
            .join("; ")}`
        : `Unable to determine a git repository within ${workspaceRoot}`;
    await logToScreenshotCollector(reason);
    log("ERROR", reason, {
      workspaceRoot,
      repoCandidates,
      repoSelectionErrors,
    });
    return { status: "failed", error: reason };
  }

  const { baseBranch, mergeBase } = mergeBaseInfo;

  await logToScreenshotCollector(
    `Git repository selected for screenshots: ${workspaceDir}`
  );
  if (repoCandidates.length > 1) {
    const otherRepos = repoCandidates.filter(
      (candidate) => candidate !== workspaceDir
    );
    if (otherRepos.length > 0) {
      await logToScreenshotCollector(
        `Additional repositories detected: ${otherRepos.join(", ")}`
      );
    }
  }

  await logToScreenshotCollector(
    "Determining merge base from origin HEAD branch..."
  );
  await logToScreenshotCollector(
    `Using merge base ${mergeBase} from ${baseBranch}`
  );
  log("INFO", "Git repository selected for screenshots", {
    workspaceRoot,
    selectedRepository: workspaceDir,
    repositoryCandidates: repoCandidates,
    baseBranch,
    mergeBase,
  });

  let changedFiles =
    options.changedFiles && options.changedFiles.length > 0
      ? options.changedFiles
      : parseFileList(
          await runCommandCapture(
            "git",
            ["diff", "--name-only", `${mergeBase}..HEAD`],
            { cwd: workspaceDir }
          )
        );

  let usedWorkingTreeFallback = false;

  if (changedFiles.length === 0) {
    await logToScreenshotCollector(
      `No merge-base diff detected; falling back to working tree changes`
    );
    log("INFO", "Falling back to working tree diff for screenshots", {
      baseBranch,
      mergeBase,
    });

    const trackedDiffOutput = await runCommandCapture(
      "git",
      ["diff", "--name-only", "HEAD"],
      { cwd: workspaceDir }
    );
    const untrackedOutput = await runCommandCapture(
      "git",
      ["ls-files", "--others", "--exclude-standard"],
      { cwd: workspaceDir }
    );

    const trackedFiles = parseFileList(trackedDiffOutput);
    const untrackedFiles = parseFileList(untrackedOutput);
    const combined = new Set<string>([...trackedFiles, ...untrackedFiles]);
    changedFiles = Array.from(combined);
    usedWorkingTreeFallback = true;
  }

  if (changedFiles.length === 0) {
    const reason =
      "No changes detected in branch commits or working tree; skipping screenshots";
    await logToScreenshotCollector(reason);
    log("INFO", reason, {
      baseBranch,
      mergeBase,
    });
    return { status: "skipped", reason };
  }

  let textFiles: string[];
  if (usedWorkingTreeFallback) {
    textFiles = changedFiles;
    await logToScreenshotCollector(
      `Working tree fallback in effect; using ${textFiles.length} file(s) from git diff HEAD`
    );
  } else {
    textFiles = await filterTextFiles(workspaceDir, mergeBase, changedFiles);
    await logToScreenshotCollector(
      `Found ${textFiles.length} text file(s) with diffs out of ${changedFiles.length} total`
    );
    if (textFiles.length === 0) {
      const reason =
        "All changed files are binary; skipping screenshot collection";
      await logToScreenshotCollector("All changed files are binary; skipping");
      log("INFO", reason, {
        baseBranch,
        mergeBase,
        changedFiles,
      });
      return { status: "skipped", reason };
    }
  }

  await logToScreenshotCollector(
    `Text files queued for screenshots: ${textFiles.join(", ")}`
  );

  let commitSha: string;
  try {
    commitSha = await resolveCommitSha(workspaceDir);
    await logToScreenshotCollector(`Resolved commit ${commitSha}`);
  } catch (commitError) {
    const message =
      commitError instanceof Error
        ? commitError.message
        : String(commitError ?? "unknown commit error");
    await logToScreenshotCollector(`Failed to resolve commit: ${message}`);
    log("ERROR", "Failed to resolve commit for screenshots", {
      error: message,
    });
    return { status: "failed", error: message };
  }

  let prDescription = options.prDescription ?? null;
  if (!prDescription) {
    const descriptionSearchPaths =
      workspaceDir === workspaceRoot
        ? [workspaceDir]
        : [workspaceDir, workspaceRoot];
    let descriptionFound = false;

    for (const descriptionPath of descriptionSearchPaths) {
      try {
        const candidateDescription = await readPrDescription(descriptionPath);
        if (candidateDescription) {
          prDescription = candidateDescription;
          descriptionFound = true;
          await logToScreenshotCollector(
            `PR description detected (${candidateDescription.length} characters)`
          );
          break;
        }
      } catch (descriptionError) {
        const message =
          descriptionError instanceof Error
            ? descriptionError.message
            : String(descriptionError ?? "unknown PR description error");
        await logToScreenshotCollector(
          `Failed to read PR description from ${descriptionPath}: ${message}`
        );
        log("ERROR", "Failed to read PR description for screenshots", {
          path: descriptionPath,
          error: message,
        });
      }
    }

    if (!descriptionFound) {
      await logToScreenshotCollector(
        "No PR description found; proceeding without additional context"
      );
    }
  }

  const trimmedTaskRunJwt = options.taskRunJwt?.trim();
  const trimmedAnthropicKey =
    options.anthropicApiKey?.trim() ?? process.env.ANTHROPIC_API_KEY;

  let claudeAuth: ClaudeCodeAuthConfig | null = null;

  if (trimmedTaskRunJwt) {
    claudeAuth = { auth: { taskRunJwt: trimmedTaskRunJwt } };
    await logToScreenshotCollector(
      "Using taskRun JWT for Claude Code screenshot collection"
    );
    await logToScreenshotCollector(
      `JWT details: present=${!!trimmedTaskRunJwt}, length=${trimmedTaskRunJwt?.length ?? 0}, first 20 chars=${trimmedTaskRunJwt?.substring(0, 20) ?? "N/A"}`
    );
  } else if (trimmedAnthropicKey) {
    claudeAuth = { auth: { anthropicApiKey: trimmedAnthropicKey } };
    await logToScreenshotCollector(
      `ANTHROPIC_API_KEY source: ${
        options.anthropicApiKey?.trim() ? "payload" : "environment"
      }`
    );
    await logToScreenshotCollector(
      `ANTHROPIC_API_KEY (first 8 chars): ${
        trimmedAnthropicKey.slice(0, 8) ?? "<none>"
      }`
    );
  } else {
    const reason =
      "Missing Claude auth (taskRunJwt or ANTHROPIC_API_KEY required for screenshot collection)";
    await logToScreenshotCollector(reason);
    await logToScreenshotCollector(
      `Auth debug: taskRunJwt=${options.taskRunJwt ? "present" : "missing"}, anthropicApiKey=${options.anthropicApiKey ? "present" : "missing"}, env ANTHROPIC_API_KEY=${process.env.ANTHROPIC_API_KEY ? "present" : "missing"}`
    );
    log("ERROR", reason, { baseBranch, mergeBase });
    return { status: "skipped", reason, commitSha };
  }

  const headBranch =
    options.headBranch ?? (await detectHeadBranch(workspaceDir)) ?? "HEAD";
  await logToScreenshotCollector(`Using head branch ${headBranch}`);

  const prTitle = resolvePrTitle({
    explicitTitle: options.prTitle,
    prDescription,
    headBranch,
  });

  const { outputDir, copyTarget } = resolveOutputDirectory(
    headBranch,
    collectorModule,
    options.outputPath
  );

  await logToScreenshotCollector(`Claude collector output dir: ${outputDir}`);

  try {
    const claudeResult = await collectorModule.claudeCodeCapturePRScreenshots({
      workspaceDir,
      changedFiles: textFiles,
      prTitle,
      prDescription: prDescription ?? "",
      baseBranch,
      headBranch,
      outputDir,
      pathToClaudeCodeExecutable: "/root/.bun/bin/claude",
      installCommand: options.installCommand ?? undefined,
      devCommand: options.devCommand ?? undefined,
      convexSiteUrl: normalizedConvexUrl,
      ...claudeAuth,
    });

    if (claudeResult.status === "completed") {
      const collectedScreenshots = claudeResult.screenshots ?? [];
      const collectedVideos = claudeResult.videos ?? [];
      if (collectedScreenshots.length === 0 && collectedVideos.length === 0) {
        // If Claude explicitly reported no UI changes, this is expected - not an error
        if (claudeResult.hasUiChanges === false) {
          const reason = "No UI changes detected in this PR";
          await logToScreenshotCollector(reason);
          log("INFO", reason, { headBranch, outputDir });
          return { status: "skipped", reason, commitSha, hasUiChanges: false };
        }
        if (claudeResult.hasUiChanges === undefined) {
          const reason = "No UI changes detected in this PR";
          await logToScreenshotCollector(
            `${reason} (collector returned no screenshots or videos)`
          );
          log(
            "WARN",
            "Claude collector returned no media without hasUiChanges; treating as no UI changes",
            { headBranch, outputDir }
          );
          return { status: "skipped", reason, commitSha, hasUiChanges: false };
        }
        // Otherwise, Claude thought there were UI changes but returned no files - unexpected
        const error =
          "Claude collector reported success but returned no files";
        await logToScreenshotCollector(error);
        log("ERROR", error, { headBranch, outputDir });
        return {
          status: "failed",
          error,
          commitSha,
          hasUiChanges: claudeResult.hasUiChanges,
        };
      }

      const screenshotEntries: CapturedScreenshot[] =
        collectedScreenshots.map((screenshot) => ({
          path: screenshot.path,
          fileName: path.basename(screenshot.path),
          description: screenshot.description,
        }));

      const videoEntries: CapturedVideo[] =
        collectedVideos.map((video) => ({
          path: video.path,
          fileName: path.basename(video.path),
          description: video.description,
        }));

      // At least one of screenshots or videos must be present
      if (screenshotEntries.length === 0 && videoEntries.length === 0) {
        const error = "Claude collector produced no media entries";
        await logToScreenshotCollector(error);
        log("ERROR", error, {
          headBranch,
          outputDir,
          screenshotPaths: collectedScreenshots.map(
            (screenshot) => screenshot.path
          ),
          videoPaths: collectedVideos.map((video) => video.path),
        });
        return { status: "failed", error, commitSha };
      }

      // Handle primary screenshot for copy target (only if screenshots exist)
      if (screenshotEntries.length > 0) {
        const initialPrimary = screenshotEntries[0];
        if (initialPrimary && typeof copyTarget === "string" && copyTarget.length > 0) {
          try {
            await fs.mkdir(path.dirname(copyTarget), { recursive: true });
            await fs.copyFile(initialPrimary.path, copyTarget);
            const updatedScreenshot: CapturedScreenshot = {
              path: copyTarget,
              fileName: path.basename(copyTarget),
              description: initialPrimary.description,
            };
            screenshotEntries[0] = updatedScreenshot;
            await logToScreenshotCollector(
              `Primary screenshot copied to requested path: ${copyTarget}`
            );
          } catch (copyError) {
            const message =
              copyError instanceof Error
                ? copyError.message
                : String(copyError ?? "unknown copy error");
            await logToScreenshotCollector(
              `Failed to copy screenshot to requested path: ${message}`
            );
            log("WARN", "Failed to copy screenshot to requested path", {
              headBranch,
              outputDir,
              copyTarget,
              error: message,
            });
          }
        }
      }

      // Log capture summary
      const mediaSummary = [
        screenshotEntries.length > 0 ? `${screenshotEntries.length} screenshot(s)` : null,
        videoEntries.length > 0 ? `${videoEntries.length} video(s)` : null,
      ].filter(Boolean).join(" and ");
      await logToScreenshotCollector(`Captured ${mediaSummary}`);

      // Write manifest.json with hasUiChanges and media info for local docker workflows
      const manifestPath = path.join(outputDir, "manifest.json");
      const manifest = {
        hasUiChanges: claudeResult.hasUiChanges,
        images: screenshotEntries.map((entry) => ({
          path: entry.path,
          description: entry.description,
        })),
        videos: videoEntries.map((entry) => ({
          path: entry.path,
          description: entry.description,
        })),
      };
      try {
        await fs.writeFile(manifestPath, JSON.stringify(manifest, null, 2));
        await logToScreenshotCollector(`Wrote manifest to ${manifestPath}`);
      } catch (manifestError) {
        const message =
          manifestError instanceof Error
            ? manifestError.message
            : String(manifestError ?? "unknown manifest write error");
        await logToScreenshotCollector(
          `Failed to write manifest.json: ${message}`
        );
      }

      log("INFO", "Claude collector completed", {
        headBranch,
        baseBranch,
        commitSha,
        screenshotCount: screenshotEntries.length,
        videoCount: videoEntries.length,
      });

      return {
        status: "completed",
        screenshots: screenshotEntries,
        videos: videoEntries,
        commitSha,
        hasUiChanges: claudeResult.hasUiChanges,
      };
    }

    if (claudeResult.status === "skipped") {
      const reason = claudeResult.reason ?? "Claude collector skipped";
      await logToScreenshotCollector(reason);
      return { status: "skipped", reason, commitSha };
    }

    const error = claudeResult.error ?? "Claude collector failed";
    await logToScreenshotCollector(`Claude collector failed: ${error}`);
    log("ERROR", "Claude screenshot collector failed", {
      error,
      headBranch,
      baseBranch,
    });
    return { status: "failed", error, commitSha };
  } catch (error) {
    const reason =
      error instanceof Error ? error.message : String(error ?? "unknown error");
    await logToScreenshotCollector(
      `start-screenshot-collection failed: ${reason}`
    );
    log("ERROR", "Failed to run Claude screenshot collector", {
      path: SCREENSHOT_COLLECTOR_LOG_PATH,
      openVSCodeUrl: SCREENSHOT_COLLECTOR_DIRECTORY_URL,
      error: reason,
    });
    return { status: "failed", error: reason, commitSha };
  }
}
