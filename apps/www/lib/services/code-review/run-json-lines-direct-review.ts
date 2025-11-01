import { createOpenAI } from "@ai-sdk/openai";
import { generateObject } from "ai";
import { api } from "@cmux/convex/api";
import type { Id } from "@cmux/convex/dataModel";
import { getConvex } from "@/lib/utils/get-convex";
import {
  collectPrDiffs,
  mapWithConcurrency,
} from "@/scripts/pr-review-heatmap";
import { formatUnifiedDiffWithLineNumbers } from "@/scripts/pr-review/diff-utils";
import {
  buildJsonLinesPrompt,
  jsonLinesZodSchema,
  type JsonLinesResult,
} from "@/scripts/pr-review/strategies/json-lines";

interface JsonLinesDirectReviewConfig {
  jobId: string;
  teamId?: string;
  prUrl: string;
  prNumber?: number;
  accessToken: string;
  callbackToken: string;
  githubAccessToken?: string | null;
  showDiffLineNumbers?: boolean;
  showContextLineNumbers?: boolean;
}

const JSON_LINES_DIRECT_SANDBOX_ID = "json-lines-direct-no-vm";
const DEFAULT_SHOW_DIFFERENCE_LINE_NUMBERS = false;
const DEFAULT_SHOW_CONTEXT_LINE_NUMBERS = true;
const CONCURRENCY = 6;

class JsonLinesProcessingError extends Error {
  filePath: string;

  constructor(filePath: string, cause: unknown) {
    const baseMessage =
      cause instanceof Error ? cause.message : String(cause ?? "Unknown error");
    super(baseMessage, cause instanceof Error ? { cause } : undefined);
    this.filePath = filePath;
    this.name = "JsonLinesProcessingError";
  }
}

export async function runJsonLinesDirectReview(
  config: JsonLinesDirectReviewConfig
): Promise<void> {
  console.info("[json-lines-direct] Starting review (no Morph)", {
    jobId: config.jobId,
    prUrl: config.prUrl,
  });

  const openAiApiKey = process.env.OPENAI_API_KEY;
  if (!openAiApiKey) {
    throw new Error("OPENAI_API_KEY environment variable is required");
  }

  const convex = getConvex({ accessToken: config.accessToken });
  const jobStart = Date.now();

  const githubToken =
    config.githubAccessToken ??
    process.env.GITHUB_TOKEN ??
    process.env.GH_TOKEN ??
    process.env.GITHUB_PERSONAL_ACCESS_TOKEN ??
    null;

  if (!githubToken) {
    throw new Error(
      "GitHub access token is required to run the json-lines-direct review strategy."
    );
  }

  try {
    console.info("[json-lines-direct] Fetching PR diffs from GitHub", {
      jobId: config.jobId,
      prUrl: config.prUrl,
    });

    const { metadata, fileDiffs } = await collectPrDiffs({
      prIdentifier: config.prUrl,
      includePaths: [],
      maxFiles: null,
      githubToken,
    });

    const sortedFiles = [...fileDiffs].sort((a, b) =>
      a.filePath.localeCompare(b.filePath)
    );

    if (sortedFiles.length === 0) {
      console.info("[json-lines-direct] No diff content to review", {
        jobId: config.jobId,
      });
    }

    console.info("[json-lines-direct] Processing files", {
      jobId: config.jobId,
      fileCount: sortedFiles.length,
    });

    const openai = createOpenAI({ apiKey: openAiApiKey });
    const showDiffLineNumbers =
      config.showDiffLineNumbers ?? DEFAULT_SHOW_DIFFERENCE_LINE_NUMBERS;
    const showContextLineNumbers =
      config.showContextLineNumbers ?? DEFAULT_SHOW_CONTEXT_LINE_NUMBERS;

    const settled = await mapWithConcurrency(
      sortedFiles,
      CONCURRENCY,
      async (file, index) => {
        const label = `[json-lines-direct] [${
          index + 1
        }/${sortedFiles.length}] ${file.filePath}`;
        try {
          console.info(`${label}: formatting diff`);
          const formattedDiff = formatUnifiedDiffWithLineNumbers(
            file.diffText,
            {
              showLineNumbers: showDiffLineNumbers,
              includeContextLineNumbers: showContextLineNumbers,
            }
          );

          const prompt = buildJsonLinesPrompt({
            filePath: file.filePath,
            diff: file.diffText,
            formattedDiff,
            showDiffLineNumbers,
            showContextLineNumbers,
          });

          console.info(`${label}: calling OpenAI gpt-5-codex`);
          const start = Date.now();
          const { object: structuredResult } = await generateObject<
            typeof jsonLinesZodSchema
          >({
            model: openai("gpt-5-codex"),
            schema: jsonLinesZodSchema,
            prompt,
            temperature: 0,
            maxRetries: 2,
          });
          const elapsedMs = Date.now() - start;
          const lineCount = structuredResult.lines.length;
          console.info(
            `${label}: ✓ received ${lineCount} line(s) in ${elapsedMs}ms`
          );

          await convex.mutation(api.codeReview.upsertFileOutputFromCallback, {
            jobId: config.jobId as Id<"automatedCodeReviewJobs">,
            callbackToken: config.callbackToken,
            filePath: file.filePath,
            codexReviewOutput: structuredResult,
            sandboxInstanceId: JSON_LINES_DIRECT_SANDBOX_ID,
          });

          console.info(
            `${label}: stored review output (${lineCount} line(s))`
          );

          return {
            filePath: file.filePath,
            lines: structuredResult.lines,
          };
        } catch (error) {
          console.error(`${label}: ✗ failed`, error);
          throw new JsonLinesProcessingError(file.filePath, error);
        }
      }
    );

    const successes: Array<{ filePath: string; lines: JsonLinesResult["lines"] }> =
      [];
    const failures: Array<{ filePath: string; message: string }> = [];

    for (const result of settled) {
      if (result.status === "fulfilled") {
        successes.push(result.value);
      } else {
        const reason = result.reason;
        const filePath =
          reason instanceof JsonLinesProcessingError
            ? reason.filePath
            : "<unknown>";
        const message =
          reason instanceof Error
            ? reason.message
            : String(reason ?? "Unknown error");
        failures.push({ filePath, message });
      }
    }

    console.info("[json-lines-direct] All files processed", {
      jobId: config.jobId,
      successes: successes.length,
      failures: failures.length,
    });

    const codeReviewOutput = {
      strategy: "json-lines-direct",
      pr: {
        url: metadata.prUrl,
        number: metadata.number,
        repo: `${metadata.owner}/${metadata.repo}`,
        title: metadata.title,
      },
      files: successes,
      failures,
    };

    await convex.mutation(api.codeReview.completeJobFromCallback, {
      jobId: config.jobId as Id<"automatedCodeReviewJobs">,
      callbackToken: config.callbackToken,
      sandboxInstanceId: JSON_LINES_DIRECT_SANDBOX_ID,
      codeReviewOutput,
    });

    console.info("[json-lines-direct] Review completed", {
      jobId: config.jobId,
      durationMs: Date.now() - jobStart,
      successes: successes.length,
      failures: failures.length,
    });
  } catch (error) {
    const message =
      error instanceof Error ? error.message : String(error ?? "Unknown error");
    console.error("[json-lines-direct] Review failed", {
      jobId: config.jobId,
      error: message,
      durationMs: Date.now() - jobStart,
    });

    await convex.mutation(api.codeReview.failJob, {
      jobId: config.jobId as Id<"automatedCodeReviewJobs">,
      errorCode: "pr_review_failed",
      errorDetail: message,
    });

    throw error;
  }
}
