#!/usr/bin/env bun

import { rm } from "node:fs/promises";
import { execFile, spawn } from "node:child_process";
import { promisify } from "node:util";
import {
  codeReviewCallbackSchema,
  type CodeReviewCallbackPayload,
  codeReviewFileCallbackSchema,
  type CodeReviewFileCallbackPayload,
} from "@cmux/shared/codeReview/callback-schemas";

interface CommandOptions {
  cwd?: string;
  env?: NodeJS.ProcessEnv;
}

const execFileAsync = promisify(execFile);

function formatDuration(ms: number): string {
  if (!Number.isFinite(ms)) {
    return `${ms}`;
  }
  if (ms < 1000) {
    return `${ms.toFixed(0)}ms`;
  }
  const seconds = ms / 1000;
  if (seconds < 60) {
    return `${seconds.toFixed(2)}s`;
  }
  const minutes = Math.floor(seconds / 60);
  const remainder = seconds - minutes * 60;
  return `${minutes}m ${remainder.toFixed(1)}s`;
}

interface CallbackContext {
  url: string;
  token: string;
  jobId: string;
  sandboxInstanceId?: string;
}

interface FileCallbackContext {
  url: string;
  token: string;
  jobId: string;
  sandboxInstanceId?: string;
  commitRef?: string | null;
}

async function sendCallback(
  context: CallbackContext,
  payload: CodeReviewCallbackPayload
): Promise<void> {
  const validated = codeReviewCallbackSchema.parse(payload);
  const response = await fetch(context.url, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      Authorization: `Bearer ${context.token}`,
    },
    body: JSON.stringify(validated),
  });
  if (!response.ok) {
    const text = await response.text();
    throw new Error(
      `Callback failed with status ${response.status}: ${text.slice(0, 2048)}`
    );
  }
}

async function sendFileCallback(
  context: FileCallbackContext,
  payload: CodeReviewFileCallbackPayload
): Promise<void> {
  const validated = codeReviewFileCallbackSchema.parse(payload);
  const response = await fetch(context.url, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      Authorization: `Bearer ${context.token}`,
    },
    body: JSON.stringify(validated),
  });
  if (!response.ok) {
    const text = await response.text();
    throw new Error(
      `File callback failed with status ${response.status}: ${text.slice(0, 2048)}`
    );
  }
}

async function runCommand(
  command: string,
  args: readonly string[],
  options: CommandOptions = {}
): Promise<void> {
  await new Promise<void>((resolve, reject) => {
    const child = spawn(command, args, {
      stdio: "inherit",
      cwd: options.cwd,
      env: options.env,
      shell: false,
    });

    child.once("error", (error) => reject(error));
    child.once("close", (code, signal) => {
      if (code === 0) {
        resolve();
        return;
      }
      reject(
        new Error(
          `Command "${command} ${args.join(" ")}" exited with ${
            code === null ? `signal ${String(signal)}` : `code ${code}`
          }`
        )
      );
    });
  });
}

async function runCommandCapture(
  command: string,
  args: readonly string[],
  options: CommandOptions = {}
): Promise<string> {
  const result = await execFileAsync(command, args, {
    cwd: options.cwd,
    env: options.env,
    maxBuffer: 10 * 1024 * 1024,
  });
  return result.stdout;
}

function requireEnv(name: string): string {
  const value = process.env[name];
  if (!value) {
    throw new Error(`Missing required environment variable: ${name}`);
  }
  return value;
}

function parseFileList(output: string): string[] {
  return output
    .split("\n")
    .map((line) => line.trim())
    .filter((line) => line.length > 0)
    .sort((a, b) => a.localeCompare(b));
}

function logFileSection(label: string, files: string[]): void {
  console.log("[inject] ------------------------------");
  console.log(`[inject] ${label} (${files.length})`);
  if (files.length === 0) {
    console.log("[inject]   (none)");
    return;
  }
  files.forEach((file) => {
    console.log(`[inject]   ${file}`);
  });
}

function logIndentedBlock(header: string, content: string): void {
  console.log(header);
  const normalized = content.replace(/\r\n/g, "\n").trim();
  if (!normalized) {
    console.log("[inject]   (empty response)");
    return;
  }
  normalized.split("\n").forEach((line) => {
    console.log(`[inject]   ${line}`);
  });
}

function isFulfilled<T>(
  result: PromiseSettledResult<T>
): result is PromiseFulfilledResult<T> {
  return result.status === "fulfilled";
}

interface RepoIdentifier {
  owner: string;
  name: string;
}

function parseRepoUrl(repoUrl: string): RepoIdentifier {
  let url: URL;
  try {
    url = new URL(repoUrl);
  } catch (error) {
    throw new Error(
      `Unable to parse repository URL (${repoUrl}): ${String(
        error instanceof Error ? error.message : error
      )}`
    );
  }

  const path = url.pathname.replace(/^\//, "").replace(/\.git$/, "");
  const [owner, name] = path.split("/");
  if (!owner || !name) {
    throw new Error(
      `Repository URL must be in the form https://github.com/<owner>/<repo>[.git], received: ${repoUrl}`
    );
  }
  return { owner, name };
}

function extractPathFromDiff(rawPath: string): string {
  const trimmed = rawPath.trim();
  const arrowIndex = trimmed.indexOf(" => ");
  if (arrowIndex === -1) {
    return trimmed;
  }

  const braceStart = trimmed.indexOf("{");
  const braceEnd = trimmed.indexOf("}");
  if (
    braceStart !== -1 &&
    braceEnd !== -1 &&
    braceEnd > braceStart &&
    braceStart < arrowIndex &&
    braceEnd > arrowIndex
  ) {
    const prefix = trimmed.slice(0, braceStart);
    const braceContent = trimmed.slice(braceStart + 1, braceEnd);
    const suffix = trimmed.slice(braceEnd + 1);
    const braceParts = braceContent.split(" => ");
    const replacement = braceParts[braceParts.length - 1] ?? "";
    return `${prefix}${replacement}${suffix}`;
  }

  const parts = trimmed.split(" => ");
  return parts[parts.length - 1] ?? trimmed;
}

async function filterTextFiles(
  workspaceDir: string,
  baseRevision: string,
  files: readonly string[]
): Promise<string[]> {
  if (files.length === 0) {
    return [];
  }

  const fileSet = new Set(files);
  const args = ["diff", "--numstat", `${baseRevision}..HEAD`, "--", ...files];

  const output = await runCommandCapture("git", args, { cwd: workspaceDir });
  const textFiles = new Set<string>();

  output.split("\n").forEach((line) => {
    if (!line.trim()) {
      return;
    }
    const parts = line.split("\t");
    if (parts.length < 3) {
      return;
    }
    const [addedRaw, deletedRaw, ...pathParts] = parts;
    if (!addedRaw || !deletedRaw || pathParts.length === 0) {
      return;
    }
    const added = addedRaw.trim();
    const deleted = deletedRaw.trim();
    if (added === "-" || deleted === "-") {
      // Binary diff shows "-" for text stats.
      return;
    }
    const rawPath = pathParts.join("\t").trim();
    if (!rawPath) {
      return;
    }
    const normalizedPath = extractPathFromDiff(rawPath);
    if (fileSet.has(normalizedPath)) {
      textFiles.add(normalizedPath);
      return;
    }
    if (fileSet.has(rawPath)) {
      textFiles.add(rawPath);
      return;
    }
    textFiles.add(normalizedPath);
  });

  return files.filter((file) => textFiles.has(file));
}

interface CodexReviewResult {
  file: string;
  response: string;
}

interface CodexReviewContext {
  workspaceDir: string;
  baseRevision: string;
  files: readonly string[];
  jobId: string;
  sandboxInstanceId: string;
  commitRef: string | null;
  fileCallback?: FileCallbackContext | null;
}

async function runCodexReviews({
  workspaceDir,
  baseRevision,
  files,
  jobId,
  sandboxInstanceId,
  commitRef,
  fileCallback,
}: CodexReviewContext): Promise<CodexReviewResult[]> {
  if (files.length === 0) {
    console.log("[inject] No text files require Codex review.");
    return [];
  }

  const openAiApiKey = requireEnv("OPENAI_API_KEY");

  console.log(
    `[inject] Launching Codex reviews for ${files.length} file(s)...`
  );

  const { Codex } = await import("@openai/codex-sdk");
  const codex = new Codex({ apiKey: openAiApiKey });

  const reviewStart = performance.now();

  const reviewPromises = files.map(async (file) => {
    const fileStart = performance.now();
    try {
      const diff = await runCommandCapture(
        "git",
        ["diff", `${baseRevision}..HEAD`, "--", file],
        { cwd: workspaceDir }
      );
      const thread = codex.startThread({
        workingDirectory: workspaceDir,
        model: "gpt-5-codex",
      });
      const prompt = `\
You are a senior engineer performing a focused pull request review, focusing only on the diffs in the file provided.
File path: ${file}
Return a JSON object of type { lines: { line: string, shouldBeReviewedScore: number | null, shouldReviewWhy: string | null, mostImportantCharacterIndex: number }[] }.
You should only have the "post-diff" array of lines in the JSON object
shouldBeReviewedScore is a number from 0 to 1 that indicates how careful the reviewer should be when reviewing this line of code.
Anything that feels like it might be off or might warrant a comment should have a high score, even if it's technically correct.
shouldReviewWhy should be a concise (4-10 words) hint on why the reviewer should maybe review this line of code, but it shouldn't state obvious things, instead it should only be a hint for the reviewer as to what exactly you meant when you flagged it.
In most cases, the reason should follow a template like "<X> <verb> <Y>" (eg. "line is too long" or "code accesses sensitive data").
It should be understandable by a human and make sense (break the "X is Y" rule if it helps you make it more understandable).
mostImportantCharacterIndex should be the index of the character that you deem most important in the review; if you're not sure or there are multiple, just choose any one of them.
Ugly code should be given a higher score.
Code that may be hard to read for a human should also be given a higher score.
Non-clean code too.
Only return lines that are actually interesting to review. Do not return lines that a human would not care about. But you should still be thorough and cover all interesting/suspicious lines.

The diff:
${diff || "(no diff output)"}`;

      logIndentedBlock(`[inject] Prompt for ${file}`, prompt);

      const turn = await thread.runStreamed(prompt, {
        outputSchema: {
          type: "object",
          properties: {
            lines: {
              type: "array",
              items: {
                type: "object",
                properties: {
                  line: { type: "string" },
                  shouldBeReviewedScore: { type: ["number", "null"] as const },
                  shouldReviewWhy: { type: ["string", "null"] as const },
                  mostImportantCharacterIndex: { type: "number" },
                },
                required: [
                  "line",
                  "shouldBeReviewedScore",
                  "shouldReviewWhy",
                  "mostImportantCharacterIndex",
                ],
                additionalProperties: false,
              },
            },
          },
          required: ["lines"],
          additionalProperties: false,
        } as const,
      });
      let response = "<no response>";
      for await (const event of turn.events) {
        console.log(`[inject] Codex event: ${JSON.stringify(event)}`);
        if (event.type === "item.completed") {
          if (event.item.type === "agent_message") {
            response = event.item.text;
          }
        }
      }
      // const response = turn.finalResponse ?? "";
      logIndentedBlock(`[inject] Codex review for ${file}`, response);

      const result: CodexReviewResult = { file, response };
      const elapsedMs = performance.now() - fileStart;
      console.log(
        `[inject] Review completed for ${file} in ${formatDuration(elapsedMs)}`
      );

      if (fileCallback) {
        try {
          await sendFileCallback(fileCallback, {
            jobId,
            sandboxInstanceId,
            filePath: file,
            commitRef: commitRef ?? undefined,
            codexReviewOutput: result,
          });
          console.log(`[inject] File callback delivered for ${file}`);
        } catch (callbackError) {
          const callbackMessage =
            callbackError instanceof Error
              ? callbackError.message
              : String(callbackError ?? "unknown callback error");
          console.error(
            `[inject] Failed to send file callback for ${file}: ${callbackMessage}`
          );
        }
      }

      return result;
    } catch (error) {
      const reason =
        error instanceof Error
          ? error.message
          : String(error ?? "unknown error");
      const elapsedMs = performance.now() - fileStart;
      console.error(`[inject] Codex review failed for ${file}: ${reason}`);
      console.error(
        `[inject] Review for ${file} failed after ${formatDuration(elapsedMs)}`
      );
      if (error instanceof Error) {
        throw error;
      }
      throw new Error(reason);
    }
  });

  const settledResults = await Promise.allSettled(reviewPromises);
  const failureCount = settledResults.filter(
    (result) => result.status === "rejected"
  ).length;

  if (failureCount > 0) {
    throw new Error(
      `[inject] Codex review encountered ${failureCount} failure(s). See logs above.`
    );
  }

  const collectedResults = settledResults
    .filter(isFulfilled)
    .map((result) => result.value);

  console.log(
    `[inject] Codex reviews completed in ${formatDuration(
      performance.now() - reviewStart
    )}.`
  );
  return collectedResults;
}

async function main(): Promise<void> {
  const workspaceDir = requireEnv("WORKSPACE_DIR");
  const prUrl = requireEnv("PR_URL");
  const headRepoUrl = requireEnv("GIT_REPO_URL");
  const headRefName = requireEnv("GIT_BRANCH");
  const baseRepoUrl = requireEnv("BASE_REPO_URL");
  const baseRefName = requireEnv("BASE_REF_NAME");
  const callbackUrl = process.env.CALLBACK_URL ?? null;
  const callbackToken = process.env.CALLBACK_TOKEN ?? null;
  const fileCallbackUrl = process.env.FILE_CALLBACK_URL ?? null;
  const fileCallbackToken = process.env.FILE_CALLBACK_TOKEN ?? null;
  const jobId = requireEnv("JOB_ID");
  const sandboxInstanceId = requireEnv("SANDBOX_INSTANCE_ID");
  const logFilePath = process.env.LOG_FILE_PATH ?? null;
  const logSymlinkPath = process.env.LOG_SYMLINK_PATH ?? null;
  const teamId = process.env.TEAM_ID ?? null;
  const repoFullName = process.env.REPO_FULL_NAME ?? null;
  const commitRef = process.env.COMMIT_REF ?? null;

  const callbackContext: CallbackContext | null =
    callbackUrl && callbackToken
      ? {
          url: callbackUrl,
          token: callbackToken,
          jobId,
          sandboxInstanceId,
        }
      : null;

  const fileCallbackContext: FileCallbackContext | null =
    fileCallbackUrl && fileCallbackToken
      ? {
          url: fileCallbackUrl,
          token: fileCallbackToken,
          jobId,
          sandboxInstanceId,
          commitRef,
        }
      : null;

  if (logFilePath) {
    console.log(`[inject] Logging output to ${logFilePath}`);
  }
  if (logSymlinkPath) {
    console.log(`[inject] Workspace log symlink will be ${logSymlinkPath}`);
  }

  const headRepo = parseRepoUrl(headRepoUrl);
  const baseRepo = parseRepoUrl(baseRepoUrl);

  console.log(`[inject] Preparing review workspace for ${prUrl}`);
  console.log(
    `[inject] Head ${headRepo.owner}/${headRepo.name}@${headRefName}`
  );
  console.log(
    `[inject] Base ${baseRepo.owner}/${baseRepo.name}@${baseRefName}`
  );

  const jobStart = performance.now();

  try {
    console.log(`[inject] Clearing workspace ${workspaceDir}...`);
    await rm(workspaceDir, { recursive: true, force: true });

    const cloneAndCheckout = (async () => {
      console.log(`[inject] Cloning ${headRepoUrl} into ${workspaceDir}...`);
      await runCommand("git", ["clone", headRepoUrl, workspaceDir]);
      console.log(`[inject] Checking out branch ${headRefName}...`);
      await runCommand("git", ["checkout", headRefName], {
        cwd: workspaceDir,
      });
    })();

    const installCodex = (async () => {
      console.log("[inject] Installing runtime dependencies globally...");
      await runCommand("bun", [
        "add",
        "-g",
        "@openai/codex@latest",
        "@openai/codex-sdk@latest",
        "zod@latest",
      ]);
    })();

    await Promise.all([cloneAndCheckout, installCodex]);

    if (logFilePath && logSymlinkPath) {
      try {
        await runCommand("ln", ["-sf", logFilePath, logSymlinkPath]);
        console.log(
          `[inject] Linked ${logSymlinkPath} -> ${logFilePath} for log access`
        );
      } catch (error) {
        const message =
          error instanceof Error
            ? error.message
            : String(error ?? "unknown error");
        console.warn(
          `[inject] Failed to create workspace log symlink: ${message}`
        );
      }
    }

    const baseRemote =
      headRepo.owner === baseRepo.owner && headRepo.name === baseRepo.name
        ? "origin"
        : "base";

    if (baseRemote !== "origin") {
      console.log(`[inject] Adding remote ${baseRemote} -> ${baseRepoUrl}`);
      await runCommand("git", ["remote", "add", baseRemote, baseRepoUrl], {
        cwd: workspaceDir,
      });
    }

    console.log(`[inject] Fetching ${baseRemote}/${baseRefName}...`);
    await runCommand("git", ["fetch", baseRemote, baseRefName], {
      cwd: workspaceDir,
    });

    const baseRevision = `${baseRemote}/${baseRefName}`;
    const mergeBaseRaw = await runCommandCapture(
      "git",
      ["merge-base", "HEAD", baseRevision],
      { cwd: workspaceDir }
    );
    const mergeBaseRevision = mergeBaseRaw.split("\n")[0]?.trim();
    if (!mergeBaseRevision) {
      throw new Error(
        `[inject] Unable to determine merge base between HEAD and ${baseRevision}`
      );
    }
    console.log(
      `[inject] Using merge-base ${mergeBaseRevision} for diff comparisons`
    );
    const [changedFilesOutput, modifiedFilesOutput] = await Promise.all([
      runCommandCapture(
        "git",
        ["diff", "--name-only", `${mergeBaseRevision}..HEAD`],
        {
          cwd: workspaceDir,
        }
      ),
      runCommandCapture(
        "git",
        [
          "diff",
          "--diff-filter=M",
          "--name-only",
          `${mergeBaseRevision}..HEAD`,
        ],
        { cwd: workspaceDir }
      ),
    ]);

    const changedFiles = parseFileList(changedFilesOutput);
    const modifiedFiles = parseFileList(modifiedFilesOutput);

    logFileSection("All changed files", changedFiles);
    logFileSection("All modified files", modifiedFiles);

    const [textChangedFiles, textModifiedFiles] = await Promise.all([
      filterTextFiles(workspaceDir, mergeBaseRevision, changedFiles),
      filterTextFiles(workspaceDir, mergeBaseRevision, modifiedFiles),
    ]);

    logFileSection("Changed text files", textChangedFiles);
    logFileSection("Modified text files", textModifiedFiles);

    const codexReviews = await runCodexReviews({
      workspaceDir,
      baseRevision: mergeBaseRevision,
      files: textChangedFiles,
      jobId,
      sandboxInstanceId,
      commitRef,
      fileCallback: fileCallbackContext,
    });

    console.log("[inject] Done with PR review.");
    console.log(
      `[inject] Total review runtime ${formatDuration(
        performance.now() - jobStart
      )}`
    );

    const reviewOutput: Record<string, unknown> = {
      prUrl,
      repoFullName: repoFullName ?? `${headRepo.owner}/${headRepo.name}`,
      headRefName,
      baseRefName,
      mergeBaseRevision,
      changedTextFiles: textChangedFiles,
      modifiedTextFiles: textModifiedFiles,
      logFilePath,
      logSymlinkPath,
      commitRef,
      teamId,
      codexReviews,
    };

    if (callbackContext) {
      await sendCallback(callbackContext, {
        status: "success",
        jobId,
        sandboxInstanceId,
        codeReviewOutput: reviewOutput,
      });
      console.log("[inject] Success callback delivered.");
    } else {
      console.log("[inject] Callback disabled; skipping success callback.");
    }
  } catch (error) {
    const message =
      error instanceof Error ? error.message : String(error ?? "unknown error");
    console.error(`[inject] Error during review: ${message}`);
    console.error(
      `[inject] Total runtime before failure ${formatDuration(
        performance.now() - jobStart
      )}`
    );
    if (callbackContext) {
      try {
        await sendCallback(callbackContext, {
          status: "error",
          jobId,
          sandboxInstanceId,
          errorCode: "inject_failed",
          errorDetail: message,
        });
        console.log("[inject] Failure callback delivered.");
      } catch (callbackError) {
        const callbackMessage =
          callbackError instanceof Error
            ? callbackError.message
            : String(callbackError ?? "unknown callback error");
        console.error(
          `[inject] Failed to send error callback: ${callbackMessage}`
        );
      }
    } else {
      console.log("[inject] Callback disabled; skipping error callback.");
    }
    throw error;
  }
}

await main().catch((error) => {
  console.error(
    error instanceof Error ? (error.stack ?? error.message) : error
  );
  process.exit(1);
});
