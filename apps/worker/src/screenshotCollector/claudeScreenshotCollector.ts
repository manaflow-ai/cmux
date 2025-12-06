import { query } from "@anthropic-ai/claude-agent-sdk";
import { promises as fs } from "node:fs";
import * as path from "node:path";
import { z } from "zod";

import { log } from "../logger";
import { logToScreenshotCollector } from "./logger";
import { formatClaudeMessage } from "./claudeMessageFormatter";

export const SCREENSHOT_STORAGE_ROOT = "/root/screenshots";

const IMAGE_EXTENSIONS = new Set([".png", ".jpg", ".jpeg", ".webp"]);

function isScreenshotFile(fileName: string): boolean {
  return IMAGE_EXTENSIONS.has(path.extname(fileName).toLowerCase());
}

const screenshotOutputSchema = z.object({
  hasUiChanges: z.boolean(),
  images: z
    .array(
      z.object({
        path: z.string().min(1),
        description: z.string().min(1),
      })
    )
    .default([]),
});

type ScreenshotStructuredOutput = z.infer<typeof screenshotOutputSchema>;

const screenshotOutputJsonSchema = {
  $schema: "http://json-schema.org/draft-07/schema#",
  type: "object",
  additionalProperties: false,
  required: ["hasUiChanges", "images"],
  properties: {
    hasUiChanges: { type: "boolean" },
    images: {
      type: "array",
      items: {
        type: "object",
        additionalProperties: false,
        required: ["path", "description"],
        properties: {
          path: { type: "string" },
          description: { type: "string" },
        },
      },
    },
  },
} as const;

async function collectScreenshotFiles(
  directory: string
): Promise<{ files: string[]; hasNestedDirectories: boolean }> {
  const entries = await fs.readdir(directory, { withFileTypes: true });
  const files: string[] = [];
  let hasNestedDirectories = false;

  for (const entry of entries) {
    const fullPath = path.join(directory, entry.name);
    if (entry.isDirectory()) {
      hasNestedDirectories = true;
      const nested = await collectScreenshotFiles(fullPath);
      files.push(...nested.files);
    } else if (entry.isFile() && isScreenshotFile(entry.name)) {
      files.push(fullPath);
    }
  }

  return { files, hasNestedDirectories };
}

export function normalizeScreenshotOutputDir(outputDir: string): string {
  if (path.isAbsolute(outputDir)) {
    return path.normalize(outputDir);
  }
  return path.resolve(SCREENSHOT_STORAGE_ROOT, outputDir);
}

export type ClaudeCodeAuthConfig =
  | { auth: { taskRunJwt: string } }
  | { auth: { anthropicApiKey: string } };

type BranchBaseOptions = {
  workspaceDir: string;
  changedFiles: string[];
  prTitle: string;
  prDescription: string;
  outputDir: string;
  pathToClaudeCodeExecutable?: string;
  /** Command to install dependencies (e.g., "bun install", "npm install") */
  installCommand?: string;
  /** Command to start the dev server (e.g., "bun run dev", "npm run dev") */
  devCommand?: string;
};

type BranchCaptureOptions =
  | (BranchBaseOptions & { branch: string; auth: { taskRunJwt: string } })
  | (BranchBaseOptions & { branch: string; auth: { anthropicApiKey: string } });

type CaptureScreenshotsBaseOptions = BranchBaseOptions & {
  baseBranch: string;
  headBranch: string;
};

export type CaptureScreenshotsOptions =
  | (CaptureScreenshotsBaseOptions & { auth: { taskRunJwt: string } })
  | (CaptureScreenshotsBaseOptions & { auth: { anthropicApiKey: string } });

export interface ScreenshotResult {
  status: "completed" | "failed" | "skipped";
  screenshots?: { path: string; description?: string }[];
  hasUiChanges?: boolean;
  error?: string;
  reason?: string;
}

/**
 * Use Claude Agent SDK with Playwright MCP to capture screenshots
 * Assumes the workspace is already set up with the correct branch checked out
 */
function isTaskRunJwtAuth(
  auth: ClaudeCodeAuthConfig["auth"]
): auth is { taskRunJwt: string } {
  return "taskRunJwt" in auth;
}

export async function captureScreenshotsForBranch(
  options: BranchCaptureOptions
): Promise<{
  screenshots: { path: string; description?: string }[];
  hasUiChanges?: boolean;
}> {
  const {
    workspaceDir,
    changedFiles,
    prTitle,
    prDescription,
    branch,
    outputDir: requestedOutputDir,
    auth,
    installCommand,
    devCommand,
  } = options;
  const outputDir = normalizeScreenshotOutputDir(requestedOutputDir);
  const useTaskRunJwt = isTaskRunJwtAuth(auth);
  const providedApiKey = !useTaskRunJwt ? auth.anthropicApiKey : undefined;

  const devInstructions = installCommand || devCommand
    ? `
${installCommand ? `Install command: ${installCommand}` : ""}
${devCommand ? `Dev server command: ${devCommand}` : ""}`
    : "";

  const prompt = `I need you to take screenshots of the UI changes in this pull request.

PR Title: ${prTitle}
PR Description: ${prDescription || "No description provided"}

Current branch: ${branch}
Files changed in this PR:
${changedFiles.map((f) => `- ${f}`).join("\n")}

Working directory: ${workspaceDir}
Screenshot output directory: ${outputDir}
${devInstructions}
Please:
0. Read CLAUDE.md or AGENTS.md (they may be one level deeper) and install dependencies if needed
1. Start the development server if needed (${devCommand ? `use: ${devCommand}` : "check files like README.md, package.json or .devcontainer.json for dev script, explore the repository more if needed"}. check tmux panes comprehensively to see if the server is running.)
2. Wait for the server to be ready
3. Navigate to the pages/components that were modified in the PR
4. Take full-page screenshots as well as element-specific screenshots of each relevant UI view that was changed
5. Save every screenshot directly inside ${outputDir} (no subdirectories) with descriptive names like "homepage-${branch}.png"

<IMPORTANT>
Focus on capturing visual changes. If no UI changes are present, just let me know.
When providing structured_output, set hasUiChanges to true if you saw UI changes and false otherwise. Include every screenshot you saved with the absolute file path (or a path relative to ${outputDir}) and a short description of what the screenshot shows. The paths must match the files you saved.
Do not close the browser after you're done, since I will want to click around the final page you navigated to.
Do not create summary documents.
If you can't install dependencies/start the dev server, just let me know. Do not create fake html mocks. We must take screenshots of the actual ground truth UI.
</IMPORTANT>`;

  await logToScreenshotCollector(
    `Starting Claude Agent with browser MCP for branch: ${branch}`
  );

  const screenshotPaths: string[] = [];
  let structuredOutput: ScreenshotStructuredOutput | null = null;

  try {
    const hadOriginalApiKey = Object.prototype.hasOwnProperty.call(
      process.env,
      "ANTHROPIC_API_KEY"
    );
    const originalApiKey = process.env.ANTHROPIC_API_KEY;
    if (useTaskRunJwt) {
      delete process.env.ANTHROPIC_API_KEY;
      // Log JWT info for debugging
      await logToScreenshotCollector(
        `Using taskRun JWT auth. JWT present: ${!!auth.taskRunJwt}, JWT length: ${auth.taskRunJwt?.length ?? 0}, JWT first 20 chars: ${auth.taskRunJwt?.substring(0, 20) ?? "N/A"}`
      );
      await logToScreenshotCollector(
        `ANTHROPIC_BASE_URL: https://www.cmux.dev/api/anthropic`
      );
    } else if (providedApiKey) {
      process.env.ANTHROPIC_API_KEY = providedApiKey;
      await logToScreenshotCollector(
        `Using API key auth. Key present: ${!!providedApiKey}, Key length: ${providedApiKey?.length ?? 0}`
      );
    }

    await logToScreenshotCollector(
      `Arguments to Claude Code: ${JSON.stringify({
        prompt,
        cwd: workspaceDir,
        pathToClaudeCodeExecutable: options.pathToClaudeCodeExecutable,
      })}`
    );

    try {
      for await (const message of query({
        prompt,
        options: {
          // model: "claude-haiku-4-5",
          model: "claude-opus-4-5",
          // mcpServers: {
          //   "playwright": {
          //     command: "bunx",
          //     args: [
          //       "@playwright/mcp",
          //       "--cdp-endpoint",
          //       "http://0.0.0.0:39382",
          //     ],
          //   },
          // },
          mcpServers: {
            chrome: {
              command: "bunx",
              args: [
                "chrome-devtools-mcp",
                "--browserUrl",
                "http://0.0.0.0:39382",
              ],
            },
          },
          allowDangerouslySkipPermissions: true,
          permissionMode: "bypassPermissions",
          cwd: workspaceDir,
          pathToClaudeCodeExecutable: options.pathToClaudeCodeExecutable,
          outputFormat: {
            type: "json_schema",
            schema: screenshotOutputJsonSchema,
          },
          env: {
            ...process.env,
            IS_SANDBOX: "1",
            CLAUDE_CODE_ENABLE_TELEMETRY: "0",
            CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC: "1",
            ...(useTaskRunJwt
              ? {
                  ANTHROPIC_API_KEY: "sk_placeholder_cmux_anthropic_api_key",
                  ANTHROPIC_BASE_URL: "https://www.cmux.dev/api/anthropic",
                  ANTHROPIC_CUSTOM_HEADERS: `x-cmux-token:${auth.taskRunJwt}`,
                }
              : {}),
          },
          stderr: (data) =>
            logToScreenshotCollector(`[claude-code-stderr] ${data}`),
        },
      })) {
        // Format and log all message types
        const formatted = formatClaudeMessage(message);
        if (formatted) {
          await logToScreenshotCollector(formatted);
        }

        if (message.type === "result" && "structured_output" in message) {
          const parsed = screenshotOutputSchema.safeParse(
            message.structured_output
          );
          if (parsed.success) {
            structuredOutput = parsed.data;
            await logToScreenshotCollector(
              `Structured output captured (hasUiChanges=${parsed.data.hasUiChanges}, images=${parsed.data.images.length})`
            );
          } else {
            await logToScreenshotCollector(
              `Structured output validation failed: ${parsed.error.message}`
            );
          }
        }
      }
    } catch (error) {
      await logToScreenshotCollector(
        `Failed to capture screenshots with Claude Agent: ${error instanceof Error ? error.message : String(error)}`
      );
      log("ERROR", "Failed to capture screenshots with Claude Agent", {
        error: error instanceof Error ? error.message : String(error),
      });
      throw error;
    } finally {
      if (hadOriginalApiKey) {
        if (originalApiKey !== undefined) {
          process.env.ANTHROPIC_API_KEY = originalApiKey;
        } else {
          delete process.env.ANTHROPIC_API_KEY;
        }
      } else {
        delete process.env.ANTHROPIC_API_KEY;
      }
    }

    // Find all screenshot files in the output directory
    try {
      const { files, hasNestedDirectories } =
        await collectScreenshotFiles(outputDir);

      if (hasNestedDirectories) {
        await logToScreenshotCollector(
          `Detected nested screenshot folders under ${outputDir}. Please keep all screenshots directly in the output directory.`
        );
      }

      const uniqueScreens = Array.from(
        new Set(files.map((filePath) => path.normalize(filePath)))
      ).sort();
      screenshotPaths.push(...uniqueScreens);
    } catch (readError) {
      log("WARN", "Could not read screenshot directory", {
        outputDir,
        error:
          readError instanceof Error ? readError.message : String(readError),
      });
    }

    const descriptionByPath = new Map<string, string>();
    const resolvedOutputDir = path.resolve(outputDir);
    if (structuredOutput) {
      for (const image of structuredOutput.images) {
        const absolutePath = path.isAbsolute(image.path)
          ? path.normalize(image.path)
          : path.normalize(path.resolve(resolvedOutputDir, image.path));
        descriptionByPath.set(absolutePath, image.description);
      }
    }

    const screenshotsWithDescriptions = screenshotPaths.map((absolutePath) => {
      const normalized = path.normalize(absolutePath);
      return {
        path: absolutePath,
        description: descriptionByPath.get(normalized),
      };
    });

    if (
      structuredOutput &&
      structuredOutput.images.length > 0 &&
      descriptionByPath.size === 0
    ) {
      await logToScreenshotCollector(
        "Structured output provided image descriptions, but none matched saved files; ensure paths are absolute or relative to the output directory."
      );
    }

    return {
      screenshots: screenshotsWithDescriptions,
      hasUiChanges: structuredOutput?.hasUiChanges,
    };
  } catch (error) {
    const message =
      error instanceof Error ? error.message : String(error ?? "unknown error");
    await logToScreenshotCollector(
      `Failed to capture screenshots with Claude Agent: ${message}`
    );

    // Log full error details for debugging
    if (error instanceof Error) {
      if (error.stack) {
        await logToScreenshotCollector(`Stack trace: ${error.stack}`);
      }
      // Log any additional error properties
      const errorObj = error as Error & Record<string, unknown>;
      const additionalProps = Object.keys(errorObj)
        .filter((key) => !["message", "stack", "name"].includes(key))
        .map((key) => `${key}: ${JSON.stringify(errorObj[key])}`)
        .join(", ");
      if (additionalProps) {
        await logToScreenshotCollector(`Error details: ${additionalProps}`);
      }
    }

    throw error;
  }
}

/**
 * Capture screenshots for a PR
 * Assumes the workspace directory is already set up with git repo cloned
 */
export async function claudeCodeCapturePRScreenshots(
  options: CaptureScreenshotsOptions
): Promise<ScreenshotResult> {
  const {
    workspaceDir,
    changedFiles,
    prTitle,
    prDescription,
    baseBranch,
    headBranch,
    outputDir: requestedOutputDir,
    auth,
  } = options;
  const outputDir = normalizeScreenshotOutputDir(requestedOutputDir);

  try {
    await logToScreenshotCollector(
      `Starting PR screenshot capture in ${workspaceDir}`
    );

    if (changedFiles.length === 0) {
      const reason = "No files changed in PR";
      await logToScreenshotCollector(reason);
      return { status: "skipped", reason };
    }

    await logToScreenshotCollector(
      `Found ${changedFiles.length} changed files: ${changedFiles.join(", ")}`
    );

    await fs.mkdir(outputDir, { recursive: true });

    const allScreenshots: { path: string; description?: string }[] = [];
    let hasUiChanges: boolean | undefined;

    const CAPTURE_BEFORE = false;

    if (CAPTURE_BEFORE) {
      // Capture screenshots for base branch (before changes)
      await logToScreenshotCollector(
        `Capturing 'before' screenshots for base branch: ${baseBranch}`
      );
      const beforeScreenshots = await captureScreenshotsForBranch(
        isTaskRunJwtAuth(auth)
          ? {
              workspaceDir,
              changedFiles,
              prTitle,
              prDescription,
              branch: baseBranch,
              outputDir,
              auth: { taskRunJwt: auth.taskRunJwt },
              pathToClaudeCodeExecutable: options.pathToClaudeCodeExecutable,
              installCommand: options.installCommand,
              devCommand: options.devCommand,
            }
          : {
              workspaceDir,
              changedFiles,
              prTitle,
              prDescription,
              branch: baseBranch,
              outputDir,
              auth: { anthropicApiKey: auth.anthropicApiKey },
              pathToClaudeCodeExecutable: options.pathToClaudeCodeExecutable,
              installCommand: options.installCommand,
              devCommand: options.devCommand,
            }
      );
      allScreenshots.push(...beforeScreenshots.screenshots);
      if (beforeScreenshots.hasUiChanges !== undefined) {
        hasUiChanges = beforeScreenshots.hasUiChanges;
      }
      await logToScreenshotCollector(
        `Captured ${beforeScreenshots.screenshots.length} 'before' screenshots`
      );
    }

    // Capture screenshots for head branch (after changes)
    await logToScreenshotCollector(
      `Capturing 'after' screenshots for head branch: ${headBranch}`
    );
    const afterScreenshots = await captureScreenshotsForBranch(
      isTaskRunJwtAuth(auth)
        ? {
            workspaceDir,
            changedFiles,
            prTitle,
            prDescription,
            branch: headBranch,
            outputDir,
            auth: { taskRunJwt: auth.taskRunJwt },
            pathToClaudeCodeExecutable: options.pathToClaudeCodeExecutable,
            installCommand: options.installCommand,
            devCommand: options.devCommand,
          }
        : {
            workspaceDir,
            changedFiles,
            prTitle,
            prDescription,
            branch: headBranch,
            outputDir,
            auth: { anthropicApiKey: auth.anthropicApiKey },
            pathToClaudeCodeExecutable: options.pathToClaudeCodeExecutable,
            installCommand: options.installCommand,
            devCommand: options.devCommand,
          }
    );
    allScreenshots.push(...afterScreenshots.screenshots);
    if (afterScreenshots.hasUiChanges !== undefined) {
      hasUiChanges = afterScreenshots.hasUiChanges;
    }
    await logToScreenshotCollector(
      `Captured ${afterScreenshots.screenshots.length} 'after' screenshots`
    );

    await logToScreenshotCollector(
      `Screenshot capture completed. Total: ${allScreenshots.length} screenshots saved to ${outputDir}`
    );
    log("INFO", "PR screenshot capture completed", {
      screenshotCount: allScreenshots.length,
      outputDir,
    });

    return {
      status: "completed",
      screenshots: allScreenshots,
      hasUiChanges,
    };
  } catch (error) {
    const message =
      error instanceof Error ? error.message : String(error ?? "unknown error");
    await logToScreenshotCollector(`PR screenshot capture failed: ${message}`);
    log("ERROR", "PR screenshot capture failed", {
      error: message,
    });
    return {
      status: "failed",
      error: message,
    };
  }
}
