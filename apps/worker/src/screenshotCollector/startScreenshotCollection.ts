import { log } from "../logger";
import { runCommandCapture } from "../crown/utils";
import { filterTextFiles, parseFileList, resolveMergeBase } from "./git";
import {
  SCREENSHOT_COLLECTOR_DIRECTORY_URL,
  SCREENSHOT_COLLECTOR_LOG_PATH,
  logToScreenshotCollector,
} from "./logger";
import { readPrDescription } from "./context";
import { buildScreenshotPrompt, formatFileList } from "./prompt";
import { runScreenshotAnalysis } from "./analysis";

export interface StartScreenshotCollectionOptions {
  openAiApiKey?: string | null;
}

export async function startScreenshotCollection(
  options: StartScreenshotCollectionOptions = {}
): Promise<void> {
  try {
    await logToScreenshotCollector("start-screenshot-collection triggered");
    log("INFO", "Screenshot collection trigger recorded", {
      path: SCREENSHOT_COLLECTOR_LOG_PATH,
      openVSCodeUrl: SCREENSHOT_COLLECTOR_DIRECTORY_URL,
    });

    const workspaceDir = "/root/workspace";

    await logToScreenshotCollector(
      "Determining merge base from origin HEAD branch..."
    );
    const { baseBranch, mergeBase } = await resolveMergeBase(workspaceDir);
    await logToScreenshotCollector(
      `Using merge base ${mergeBase} from ${baseBranch}`
    );

    const changedFilesOutput = await runCommandCapture(
      "git",
      ["diff", "--name-only", `${mergeBase}..HEAD`],
      { cwd: workspaceDir }
    );
    const changedFiles = parseFileList(changedFilesOutput);

    if (changedFiles.length === 0) {
      await logToScreenshotCollector(
        `No changes detected relative to ${baseBranch}`
      );
      log("INFO", "No diff files detected for screenshot collection", {
        baseBranch,
        mergeBase,
      });
      return;
    }

    const textFiles = await filterTextFiles(
      workspaceDir,
      mergeBase,
      changedFiles
    );

    await logToScreenshotCollector(
      `Found ${textFiles.length} text file(s) with diffs out of ${changedFiles.length} total`
    );

    if (textFiles.length === 0) {
      await logToScreenshotCollector("All changed files are binary; skipping");
      log("INFO", "Changed files are binary; skipping screenshot collection", {
        baseBranch,
        mergeBase,
        changedFiles,
      });
      return;
    }

    await logToScreenshotCollector(
      `Text files queued for screenshots: ${textFiles.join(", ")}`
    );
    const formattedFileList = formatFileList(textFiles);
    await logToScreenshotCollector(
      `Files included in screenshot prompt:\n${formattedFileList}`
    );
    log("INFO", "Changed text files identified for screenshot collection", {
      baseBranch,
      mergeBase,
      changedFiles,
      textFiles,
    });

    let prDescription: string | null = null;
    try {
      prDescription = await readPrDescription(workspaceDir);
      if (prDescription) {
        await logToScreenshotCollector(
          `PR description detected (${prDescription.length} characters)`
        );
      } else {
        await logToScreenshotCollector(
          "No PR description found; proceeding without additional context"
        );
      }
    } catch (descriptionError) {
      const message =
        descriptionError instanceof Error
          ? descriptionError.message
          : String(descriptionError ?? "unknown PR description error");
      await logToScreenshotCollector(
        `Failed to read PR description: ${message}`
      );
      log("ERROR", "Failed to read PR description for screenshots", {
        error: message,
      });
    }

    const suppliedKey = options.openAiApiKey?.trim();
    const openAiApiKey =
      suppliedKey && suppliedKey.length > 0
        ? suppliedKey
        : process.env.OPENAI_API_KEY;

    await logToScreenshotCollector(
      `OPENAI_API_KEY source: ${suppliedKey ? "payload" : "environment"}`
    );
    await logToScreenshotCollector(
      `OPENAI_API_KEY (first 8 chars): ${
        openAiApiKey ? openAiApiKey.slice(0, 8) : "<none>"
      }`
    );

    if (!openAiApiKey) {
      await logToScreenshotCollector(
        "OPENAI_API_KEY missing; skipping Codex screenshot instructions"
      );
      log(
        "ERROR",
        "OPENAI_API_KEY is not set; cannot analyze diffs for screenshots",
        { baseBranch, mergeBase }
      );
      return;
    }

    const prompt = buildScreenshotPrompt({
      baseBranch,
      mergeBase,
      formattedFileList,
      prDescription,
    });

    await logToScreenshotCollector(`Codex prompt:\n${prompt}`);

    const analysis = await runScreenshotAnalysis({
      apiKey: openAiApiKey,
      workspaceDir,
      prompt,
      logEvent: logToScreenshotCollector,
    });

    await logToScreenshotCollector(
      `Codex response: ${JSON.stringify(analysis)}`
    );
    log("INFO", "Codex screenshot analysis completed", {
      response: analysis,
      baseBranch,
      mergeBase,
    });
  } catch (error) {
    const reason =
      error instanceof Error ? error.message : String(error ?? "unknown error");
    try {
      await logToScreenshotCollector(
        `start-screenshot-collection failed: ${reason}`
      );
    } catch (logError) {
      log("ERROR", "Failed to write screenshot collector error log", {
        error: logError instanceof Error ? logError.message : String(logError),
      });
    }
    log("ERROR", "Failed to record screenshot collection trigger", {
      path: SCREENSHOT_COLLECTOR_LOG_PATH,
      openVSCodeUrl: SCREENSHOT_COLLECTOR_DIRECTORY_URL,
      error: reason,
    });
    throw error;
  }
}
