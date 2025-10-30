import { createAnthropic } from "@ai-sdk/anthropic";
import { streamText } from "ai";

import { collectPrDiffs } from "@/scripts/pr-review-heatmap";
import { env } from "@/lib/utils/www-env";
import {
  SimpleReviewParser,
  type SimpleReviewParsedEvent,
} from "./simple-review-parser";

const SIMPLE_REVIEW_INSTRUCTIONS = `Dannotate every modified/deleted/added line of this diff with a "fake" comment at the end of each line.

For each line, you should add a comment at the end like so:
# "<mostImportantWord>" "<comment>" "<score 0-100>"

Goal is to build a heatmap to guide me through a code review, like where i should focus my eyes on.
So not necessarily where the mistakes are but which parts of the code might require more investigation
So we need to highlight non-clean code, hacky code, suspicious code, duplicated functions, etc, stuff like that.
Anything that feels like it might be off or might warrant a comment should have a high score, even if it's technically correct.
shouldReviewWhy should be a concise (4-10 words) hint on why the reviewer should maybe review this line of code, but it shouldn't state obvious things, instead It should only be a hint for the reviewer as to what exactly you meant when you flagged it.
In most cases, the reason should follow a template like "<X> <verb> <Y>" (eg. "line is too long" or "code accesses sensitive data").
It should be understandable by a human and make sense (break the "X is Y" rule if it helps you make it more understandable).
mostImportantWord must always be provided and should identify the most critical word or identifier in the line. If you're unsure, pick the earliest relevant word or token.
Ugly code should be given a higher score.
Code that may be hard to read for a human should also be given a higher score.
Non-clean code too. Type casts, type assertions, type guards, "any" types, untyped bodies to "fetch" etc. should be given a higher score.
If a line is perfectly normal, you should give it a score of 0.
Only add comments for lines that are modified/deleted/added.

DO NOT BE LAZY DO THE ENTIRE FILE. FROM START TO FINISH. DO NOT BE LAZY.`;

const SIMPLE_REVIEW_GUIDANCE = `You must respond strictly with the diff provided, keeping every line (including context) in the original order.
- Do NOT wrap the response in code fences.
- Do NOT rewrite the code or summarize; only annotate the diff lines that already exist.
- Append the inline comment in the instructed format to the end of each modified/added/removed line.
- Maintain git diff prefixes (+, -, or space) exactly as provided.
- Process the diff from top to bottom without skipping sections.`;

const MAX_CONCURRENCY = 10;

const BINARY_EXTENSIONS = [
  ".png",
  ".jpg",
  ".jpeg",
  ".gif",
  ".webp",
  ".ico",
  ".bmp",
  ".tiff",
  ".pdf",
  ".zip",
  ".tar",
  ".gz",
  ".tgz",
  ".rar",
  ".7z",
  ".mp3",
  ".mp4",
  ".mov",
  ".avi",
  ".mkv",
  ".wav",
  ".flac",
  ".exe",
  ".dll",
  ".so",
  ".dylib",
  ".wasm",
  ".psd",
  ".ai",
];

const LOCKFILE_SUFFIXES = [
  "/package-lock.json",
  "/yarn.lock",
  "/pnpm-lock.yaml",
  "/bun.lock",
  "/composer.lock",
  "/cargo.lock",
  "/podfile.lock",
  "/gemfile.lock",
  "/poetry.lock",
  "/pipfile.lock",
  "/gradle.lockfile",
  "/go.sum",
  ".lock",
];

const SKIPPED_PATH_SEGMENTS = [
  "node_modules/",
  "vendor/",
  "third_party/",
  "__pycache__/",
];

type FileDiff = {
  filePath: string;
  diffText: string;
};

export type SimpleReviewStreamOptions = {
  prIdentifier: string;
  githubToken: string;
  onChunk?: (chunk: string) => void | Promise<void>;
  onEvent?: (event: SimpleReviewParsedEvent) => void | Promise<void>;
  signal?: AbortSignal;
};

export type SimpleReviewStreamResult = {
  diffCharacterCount: number;
  finalText: string;
};

export async function runSimpleAnthropicReviewStream(
  options: SimpleReviewStreamOptions
): Promise<SimpleReviewStreamResult> {
  const { prIdentifier, githubToken, onChunk, signal } = options;
  const onEvent = options.onEvent ?? null;

  const emitEvent = async (event: SimpleReviewParsedEvent): Promise<void> => {
    if (!onEvent) {
      return;
    }
    await onEvent(event);
  };

  console.info("[simple-review] Collecting PR diffs", { prIdentifier });

  if (signal?.aborted) {
    console.warn("[simple-review] Aborted before diff collection", {
      prIdentifier,
    });
    throw new Error("Stream aborted before start");
  }

  const { fileDiffs, metadata } = await collectPrDiffs({
    prIdentifier,
    githubToken,
    includePaths: [],
    maxFiles: null,
  });

  const candidateFiles: FileDiff[] = [];

  for (const file of fileDiffs) {
    const skipReason = detectSkipReason(file.filePath, file.diffText);
    if (skipReason) {
      console.info("[simple-review] Skipping file", {
        filePath: file.filePath,
        reason: skipReason,
      });
      await emitEvent({
        type: "skip",
        filePath: file.filePath,
        reason: skipReason,
      });
      continue;
    }
    candidateFiles.push(file);
  }

  const diffCharacterCount = candidateFiles.reduce(
    (total, file) => total + file.diffText.length,
    0
  );

  if (candidateFiles.length === 0) {
    console.warn("[simple-review] No eligible text diffs found", {
      prIdentifier,
      totalFiles: fileDiffs.length,
    });
    return {
      diffCharacterCount,
      finalText: "",
    };
  }

  const prLabel =
    metadata.prUrl ??
    `${metadata.owner}/${metadata.repo}#${metadata.number ?? "unknown"}`;

  const anthropic = createAnthropic({
    apiKey: env.ANTHROPIC_API_KEY,
  });

  const runWithSemaphore = createSemaphore(MAX_CONCURRENCY);
  const finalChunks: string[] = [];

  console.info("[simple-review] Streaming files with concurrency", {
    prIdentifier,
    fileCount: candidateFiles.length,
    concurrency: MAX_CONCURRENCY,
  });

  const results = await Promise.allSettled(
    candidateFiles.map((file, index) =>
      runWithSemaphore(async () => {
        if (signal?.aborted) {
          throw new Error("Stream aborted");
        }

        await emitEvent({
          type: "file",
          filePath: file.filePath,
        });

        const parser = new SimpleReviewParser();
        let aborted = false;
        let emittedLine = false;
        const fileChunks: string[] = [];
        const handleAbort = () => {
          aborted = true;
        };

        if (signal) {
          signal.addEventListener("abort", handleAbort);
        }

        const prompt = buildFilePrompt(prLabel, file.filePath, file.diffText);

        console.info("[simple-review] Streaming file diff", {
          prIdentifier,
          filePath: file.filePath,
          ordinal: index + 1,
          total: candidateFiles.length,
        });

        try {
          const stream = streamText({
            model: anthropic("claude-opus-4-1-20250805"),
            prompt,
            temperature: 0,
            maxRetries: 2,
          });

          for await (const delta of stream.textStream) {
            if (aborted) {
              throw new Error("Stream aborted");
            }
            if (delta.length === 0) {
              continue;
            }

            finalChunks.push(delta);
            fileChunks.push(delta);

            if (onChunk) {
              await onChunk(delta);
            } else {
              console.debug("[simple-review][chunk]", delta);
            }

            const events = parser.push(delta);
            if (events.length > 0) {
              for (const event of events) {
                if (event.type === "line") {
                  emittedLine = true;
                }
                await emitEvent(event);
              }
            }
          }

          const remaining = parser.flush();
          if (remaining.length > 0) {
            for (const event of remaining) {
              if (event.type === "line") {
                emittedLine = true;
              }
              await emitEvent(event);
            }
          }

          if (!emittedLine) {
            const fileText = fileChunks.join("");
            console.warn("[simple-review] Model returned no annotations", {
              prIdentifier,
              filePath: file.filePath,
              preview: buildTextPreview(fileText),
              raw: fileText,
            });
            await emitEvent({
              type: "skip",
              filePath: file.filePath,
              reason: "model returned no annotated lines",
            });
            await emitEvent({
              type: "file-complete",
              filePath: file.filePath,
              status: "skipped",
              summary: "model returned no annotated lines",
            });
          } else {
            await emitEvent({
              type: "file-complete",
              filePath: file.filePath,
              status: "success",
            });
          }
        } catch (error) {
          const message =
            error instanceof Error
              ? error.message
              : String(error ?? "Unknown error");
          console.error("[simple-review] File stream failed", {
            prIdentifier,
            filePath: file.filePath,
            message,
          });
          await emitEvent({
            type: "skip",
            filePath: file.filePath,
            reason: `error: ${message}`,
          });
          await emitEvent({
            type: "file-complete",
            filePath: file.filePath,
            status: "error",
            summary: message,
          });
          throw error;
        } finally {
          if (signal) {
            signal.removeEventListener("abort", handleAbort);
          }
        }
      })
    )
  );

  const rejected = results.filter(
    (result): result is PromiseRejectedResult => result.status === "rejected"
  );

  if (rejected.length > 0) {
    const firstReason = rejected[0]?.reason ?? "unknown error";
    throw firstReason instanceof Error
      ? firstReason
      : new Error(String(firstReason));
  }

  const finalText = finalChunks.join("");

  console.info("[simple-review] Stream completed", {
    prIdentifier,
    processedFiles: candidateFiles.length,
    finalLength: finalText.length,
  });

  return {
    diffCharacterCount,
    finalText,
  };
}

function detectSkipReason(filePath: string, diffText: string): string | null {
  const lowerPath = filePath.toLowerCase();

  if (
    SKIPPED_PATH_SEGMENTS.some((segment) => lowerPath.includes(segment))
  ) {
    return "skipped third-party directory";
  }

  if (
    LOCKFILE_SUFFIXES.some((suffix) => lowerPath.endsWith(suffix))
  ) {
    return "skipped lockfile";
  }

  if (isLikelyBinary(lowerPath, diffText)) {
    return "skipped binary file";
  }

  return null;
}

function isLikelyBinary(filePath: string, diffText: string): boolean {
  if (
    diffText.includes("Binary files") &&
    diffText.includes("differ")
  ) {
    return true;
  }

  if (diffText.includes("GIT binary patch")) {
    return true;
  }

  return BINARY_EXTENSIONS.some((extension) =>
    filePath.endsWith(extension)
  );
}

function createSemaphore(limit: number) {
  if (limit <= 0) {
    return async <T>(task: () => Promise<T>): Promise<T> => task();
  }

  let active = 0;
  const queue: Array<() => void> = [];

  const acquire = async () => {
    if (active >= limit) {
      await new Promise<void>((resolve) => {
        queue.push(resolve);
      });
    }
    active += 1;
  };

  const release = () => {
    active = Math.max(0, active - 1);
    const next = queue.shift();
    if (next) {
      next();
    }
  };

  return async function runWithLimit<T>(
    task: () => Promise<T>
  ): Promise<T> {
    await acquire();
    try {
      return await task();
    } finally {
      release();
    }
  };
}

function buildFilePrompt(
  prLabel: string,
  filePath: string,
  diffText: string
): string {
  const strippedDiff = stripLeadingTrailingCodeFences(diffText);
  return `You are reviewing a GitHub diff for ${prLabel}
File path: ${filePath}

${SIMPLE_REVIEW_GUIDANCE}

Diff:
${strippedDiff}

${SIMPLE_REVIEW_INSTRUCTIONS}`;
}

function buildTextPreview(text: string, maxLength = 400): string {
  const collapsed = text.replace(/\s+/g, " ").trim();
  if (collapsed.length <= maxLength) {
    return collapsed;
  }
  return `${collapsed.slice(0, maxLength - 3)}...`;
}

function stripLeadingTrailingCodeFences(text: string): string {
  if (!text) {
    return text;
  }

  const lines = text.split(/\r?\n/);
  let start = 0;
  let end = lines.length - 1;

  while (start <= end && lines[start]!.trim().length === 0) {
    start += 1;
  }
  while (end >= start && lines[end]!.trim().length === 0) {
    end -= 1;
  }

  if (start > end) {
    return "";
  }

  const startsWithFence = lines[start]!.trim().startsWith("```");
  if (startsWithFence) {
    start += 1;
    while (start <= end && lines[start]!.trim().startsWith("```")) {
      start += 1;
    }
  }

  const endsWithFence = lines[end]!.trim().startsWith("```");
  if (endsWithFence) {
    end -= 1;
    while (end >= start && lines[end]!.trim().startsWith("```")) {
      end -= 1;
    }
  }

  if (start > end) {
    return "";
  }

  return lines.slice(start, end + 1).join("\n");
}
