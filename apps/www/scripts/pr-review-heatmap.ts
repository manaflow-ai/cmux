#!/usr/bin/env bun

import { execFile } from "node:child_process";
import { mkdir, writeFile } from "node:fs/promises";
import { join, resolve as resolvePath } from "node:path";
import process from "node:process";
import { promisify } from "node:util";
import { createOpenAI } from "@ai-sdk/openai";
import { streamObject, type LanguageModel } from "ai";
import { formatUnifiedDiffWithLineNumbers } from "./pr-review/diff-utils";
import {
  buildHeatmapPrompt,
  heatmapSchema,
  summarizeHeatmapStreamChunk,
} from "../lib/services/code-review/heatmap-shared";
import type { HeatmapLine } from "../lib/services/code-review/heatmap-shared";

const execFileAsync = promisify(execFile);

export type { HeatmapLine };

export interface FileDiff {
  filePath: string;
  diffText: string;
}

export interface HeatmapFileResult {
  filePath: string;
  lines: HeatmapLine[];
}

export interface HeatmapJobOptions {
  files: FileDiff[];
  concurrency: number;
  modelId: string;
  modelFactory: (modelId: string) => LanguageModel;
}

export interface HeatmapJobResult {
  successes: HeatmapFileResult[];
  failures: Array<{ filePath: string; message: string }>;
}

const DEFAULT_GITHUB_API_BASE_URL = "https://api.github.com";
const GITHUB_USER_AGENT = "cmux-pr-review-heatmap";

// Load GitHub tokens from environment variables for rotation
function loadGitHubTokensFromEnv(): string[] {
  return [
    process.env.GITHUB_TOKEN_1,
    process.env.GITHUB_TOKEN_2,
    process.env.GITHUB_TOKEN_3,
  ].filter((t): t is string => Boolean(t));
}

let currentTokenIndex = 0;

function getNextGitHubToken(): string | null {
  const tokens = loadGitHubTokensFromEnv();
  if (tokens.length === 0) {
    return null;
  }
  const token = tokens[currentTokenIndex % tokens.length];
  currentTokenIndex = (currentTokenIndex + 1) % tokens.length;
  return token;
}

interface CollectPrDiffsOptions {
  prIdentifier: string;
  includePaths?: string[];
  maxFiles?: number | null;
  githubToken?: string | null;
  githubApiBaseUrl?: string;
}

class HeatmapProcessingError extends Error {
  filePath: string;

  constructor(filePath: string, cause: unknown) {
    const baseMessage =
      cause instanceof Error ? cause.message : String(cause ?? "Unknown error");
    super(baseMessage, cause instanceof Error ? { cause } : undefined);
    this.filePath = filePath;
    this.name = "HeatmapProcessingError";
  }
}

function sanitizeFilePath(filePath: string): string {
  return filePath
    .replace(/^\.\//, "")
    .replace(/\.\./g, "__")
    .replace(/[\\/]/g, "__")
    .replace(/[^a-zA-Z0-9._-]+/g, "_");
}

function isBinaryFile(filePath: string, diffText: string): boolean {
  // Check if git marked it as binary
  if (diffText.includes("Binary files") && diffText.includes("differ")) {
    return true;
  }

  // Check common binary/image extensions
  const binaryExtensions = [
    ".png",
    ".jpg",
    ".jpeg",
    ".gif",
    ".webp",
    ".ico",
    ".svg",
    ".bmp",
    ".tiff",
    ".pdf",
    ".zip",
    ".tar",
    ".gz",
    ".rar",
    ".7z",
    ".exe",
    ".dll",
    ".so",
    ".dylib",
    ".wasm",
    ".bin",
    ".dat",
    ".db",
    ".sqlite",
    ".mp3",
    ".mp4",
    ".avi",
    ".mov",
    ".wav",
    ".ttf",
    ".otf",
    ".woff",
    ".woff2",
    ".eot",
  ];

  const lowerPath = filePath.toLowerCase();
  return binaryExtensions.some((ext) => lowerPath.endsWith(ext));
}

function formatDuration(ms: number): string {
  const seconds = Math.floor(ms / 1000);
  const minutes = Math.floor(seconds / 60);
  const remainingSeconds = seconds % 60;
  const remainingMs = ms % 1000;

  if (minutes > 0) {
    return `${minutes} min ${remainingSeconds} sec`;
  }
  if (seconds > 0) {
    return `${seconds}.${remainingMs.toString().padStart(3, "0")} sec`;
  }
  return `${ms} ms`;
}

function formatResultAsMarkdown(
  result: HeatmapFileResult & { prompt: string; duration: number },
  model: string,
  diffLabel: string,
  prMetadata: GhPrMetadata | null
): string {
  const sections: string[] = [];

  // Header
  sections.push(`# PR Review Heatmap: ${result.filePath}`);
  sections.push("");

  // Metadata
  sections.push("## Metadata");
  sections.push("");
  sections.push(`- **Model**: ${model}`);
  sections.push(`- **Diff**: ${diffLabel}`);
  sections.push(`- **Duration**: ${formatDuration(result.duration)}`);
  sections.push(`- **Lines Analyzed**: ${result.lines.length}`);
  if (prMetadata) {
    sections.push(`- **PR**: [#${prMetadata.number}](${prMetadata.prUrl})`);
    if (prMetadata.title) {
      sections.push(`- **Title**: ${prMetadata.title}`);
    }
  }
  sections.push("");

  // Prompt
  sections.push("## Prompt Sent to LLM");
  sections.push("");
  sections.push("```");
  sections.push(result.prompt);
  sections.push("```");
  sections.push("");

  // Raw JSON response
  sections.push("## Raw JSON Response");
  sections.push("");
  sections.push("```json");
  sections.push(JSON.stringify({ lines: result.lines }, null, 2));
  sections.push("```");
  sections.push("");

  // Results - rebuild diff with inline comments
  sections.push("## Analysis Results");
  sections.push("");
  sections.push("```diff");

  for (const line of result.lines) {
    // Use the original diff text when available; ensure we still output a valid diff line.
    const rawLine = line.line;
    const hasDiffMarker =
      rawLine.startsWith("+") ||
      rawLine.startsWith("-") ||
      rawLine.startsWith(" ");
    let diffLine = hasDiffMarker ? rawLine : ` ${rawLine}`;

    // Add inline comment if should review
    if (
      line.shouldBeReviewedScore !== undefined &&
      line.shouldBeReviewedScore > 0
    ) {
      const score = line.shouldBeReviewedScore.toFixed(2);
      const reason = line.shouldReviewWhy || "review needed";
      const comment = `  # ⚠️ [${score}] ${reason}`;
      diffLine = `${diffLine}${comment}`;
    }

    sections.push(diffLine);
  }

  sections.push("```");
  sections.push("");

  return sections.join("\n");
}

async function mapWithConcurrency<T, R>(
  items: readonly T[],
  concurrency: number,
  worker: (item: T, index: number) => Promise<R>
): Promise<PromiseSettledResult<R>[]> {
  if (items.length === 0) {
    return [];
  }
  const results: PromiseSettledResult<R>[] = new Array(items.length);
  let nextIndex = 0;
  const workerCount = Math.max(1, Math.min(concurrency, items.length));

  async function runWorker(): Promise<void> {
    while (true) {
      const currentIndex = nextIndex;
      if (currentIndex >= items.length) {
        break;
      }
      nextIndex += 1;
      try {
        const value = await worker(items[currentIndex] as T, currentIndex);
        results[currentIndex] = { status: "fulfilled", value };
      } catch (error) {
        results[currentIndex] = { status: "rejected", reason: error };
      }
    }
  }

  await Promise.all(Array.from({ length: workerCount }, () => runWorker()));

  return results;
}

// Export helper functions and core functions for external use
export { formatDuration, isBinaryFile, mapWithConcurrency, collectPrDiffsViaGhCli };

export async function runHeatmapJob(
  options: HeatmapJobOptions
): Promise<HeatmapJobResult> {
  const settled = await mapWithConcurrency(
    options.files,
    options.concurrency,
    async (file, index) => {
      console.log(
        `[heatmap] [${index + 1}/${options.files.length}] Processing ${file.filePath}...`
      );
      const formattedDiff = formatUnifiedDiffWithLineNumbers(file.diffText, {
        showLineNumbers: false,
        includeContextLineNumbers: false,
      });
      const prompt = buildHeatmapPrompt(file.filePath, formattedDiff);
      const startTime = Date.now();
      try {
        const stream = streamObject({
          model: options.modelFactory(options.modelId),
          schema: heatmapSchema,
          prompt,
          temperature: 0,
          maxRetries: 2,
        });

        let lastLineCount = 0;
        let hasShownReasoning = false;

        for await (const chunk of stream.fullStream) {
          const { lineCount, textDelta } = summarizeHeatmapStreamChunk(chunk);

          if (lineCount !== null && lineCount > lastLineCount) {
            process.stdout.write(
              `\r[heatmap] [${index + 1}/${options.files.length}] ${file.filePath}: ${lineCount} lines...`
            );
            lastLineCount = lineCount;
          }

          if (textDelta) {
            if (!hasShownReasoning) {
              process.stdout.write("\n");
              console.log(
                `[heatmap] [${index + 1}/${options.files.length}] 💭 Reasoning for ${file.filePath}:`
              );
              hasShownReasoning = true;
            }
            process.stdout.write(`${textDelta} `);
          }
        }

        if (hasShownReasoning) {
          process.stdout.write("\n");
        }
        if (lastLineCount > 0) {
          process.stdout.write("\n");
        }

        const finalObject = await stream.object;
        const duration = Date.now() - startTime;
        const result = {
          filePath: file.filePath,
          lines: finalObject.lines,
          prompt,
          duration,
        } satisfies HeatmapFileResult & { prompt: string; duration: number };
        console.log(
          `[heatmap] [${index + 1}/${options.files.length}] ✓ ${file.filePath}: ${result.lines.length} lines analyzed (${formatDuration(duration)})`
        );
        return result;
      } catch (error) {
        console.error(
          `[heatmap] [${index + 1}/${options.files.length}] ✗ ${file.filePath}: ${error instanceof Error ? error.message : String(error)}`
        );
        throw new HeatmapProcessingError(file.filePath, error);
      }
    }
  );

  const successes: HeatmapFileResult[] = [];
  const failures: Array<{ filePath: string; message: string }> = [];

  for (const result of settled) {
    if (result.status === "fulfilled") {
      successes.push(result.value);
      continue;
    }
    const reason = result.reason;
    if (reason instanceof HeatmapProcessingError) {
      failures.push({ filePath: reason.filePath, message: reason.message });
      continue;
    }
    failures.push({
      filePath: "<unknown>",
      message:
        reason instanceof Error ? reason.message : String(reason ?? "error"),
    });
  }

  return { successes, failures };
}

interface CliOptions {
  baseRef: string;
  headRef: string;
  concurrency: number;
  outputDir: string;
  model: string;
  maxFiles: number | null;
  includePaths: string[];
  useMergeBase: boolean;
  prIdentifier: string | null;
  githubToken: string | null;
  githubApiBaseUrl: string | null;
  preferGhCli: boolean;
  allowGhCliFallback: boolean;
}

function parseCliArgs(argv: readonly string[]): CliOptions {
  const options: CliOptions = {
    baseRef: "origin/main",
    headRef: "HEAD",
    concurrency: 50,
    outputDir: "tmp/pr-review-heatmap",
    model: "gpt-5-mini",
    maxFiles: null,
    includePaths: [],
    useMergeBase: true,
    prIdentifier: null,
    githubToken: null,
    githubApiBaseUrl: null,
    preferGhCli: false,
    allowGhCliFallback: true,
  };

  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    if (arg === "--base") {
      const value = argv[index + 1];
      if (!value) {
        throw new Error("--base flag requires a value");
      }
      options.baseRef = value;
      index += 1;
      continue;
    }
    if (arg.startsWith("--base=")) {
      options.baseRef = arg.slice("--base=".length);
      continue;
    }
    if (arg === "--head") {
      const value = argv[index + 1];
      if (!value) {
        throw new Error("--head flag requires a value");
      }
      options.headRef = value;
      index += 1;
      continue;
    }
    if (arg.startsWith("--head=")) {
      options.headRef = arg.slice("--head=".length);
      continue;
    }
    if (arg === "--model") {
      const value = argv[index + 1];
      if (!value) {
        throw new Error("--model flag requires a value");
      }
      options.model = value;
      index += 1;
      continue;
    }
    if (arg.startsWith("--model=")) {
      options.model = arg.slice("--model=".length);
      continue;
    }
    if (arg === "--output") {
      const value = argv[index + 1];
      if (!value) {
        throw new Error("--output flag requires a value");
      }
      options.outputDir = value;
      index += 1;
      continue;
    }
    if (arg.startsWith("--output=")) {
      options.outputDir = arg.slice("--output=".length);
      continue;
    }
    if (arg === "--concurrency") {
      const value = argv[index + 1];
      if (!value) {
        throw new Error("--concurrency flag requires a value");
      }
      options.concurrency = Math.max(
        1,
        Number.parseInt(value, 10) || options.concurrency
      );
      index += 1;
      continue;
    }
    if (arg.startsWith("--concurrency=")) {
      const parsed = Number.parseInt(arg.slice("--concurrency=".length), 10);
      options.concurrency = Number.isFinite(parsed) && parsed > 0 ? parsed : 1;
      continue;
    }
    if (arg === "--max-files") {
      const value = argv[index + 1];
      if (!value) {
        throw new Error("--max-files flag requires a value");
      }
      options.maxFiles = Math.max(1, Number.parseInt(value, 10) || 1);
      index += 1;
      continue;
    }
    if (arg.startsWith("--max-files=")) {
      const parsed = Number.parseInt(arg.slice("--max-files=".length), 10);
      options.maxFiles = Number.isFinite(parsed) && parsed > 0 ? parsed : 1;
      continue;
    }
    if (arg === "--github-token") {
      const value = argv[index + 1];
      if (!value) {
        throw new Error("--github-token flag requires a value");
      }
      options.githubToken = value;
      index += 1;
      continue;
    }
    if (arg.startsWith("--github-token=")) {
      options.githubToken = arg.slice("--github-token=".length);
      continue;
    }
    if (arg === "--github-api-base-url") {
      const value = argv[index + 1];
      if (!value) {
        throw new Error("--github-api-base-url flag requires a value");
      }
      options.githubApiBaseUrl = value;
      index += 1;
      continue;
    }
    if (arg.startsWith("--github-api-base-url=")) {
      options.githubApiBaseUrl = arg.slice("--github-api-base-url=".length);
      continue;
    }
    if (arg === "--use-gh-cli") {
      options.preferGhCli = true;
      options.allowGhCliFallback = true;
      continue;
    }
    if (arg === "--no-gh-cli") {
      options.allowGhCliFallback = false;
      continue;
    }
    if (arg === "--no-merge-base") {
      options.useMergeBase = false;
      continue;
    }
    if (arg === "--pr") {
      const value = argv[index + 1];
      if (!value) {
        throw new Error("--pr flag requires a value");
      }
      options.prIdentifier = value;
      index += 1;
      continue;
    }
    if (arg.startsWith("--pr=")) {
      options.prIdentifier = arg.slice("--pr=".length);
      continue;
    }
    if (arg === "--help" || arg === "-h") {
      printHelpAndExit();
    }
    options.includePaths.push(arg);
  }

  if (options.prIdentifier && options.includePaths.length > 0) {
    console.warn(
      "[heatmap] Positional file filters are applied against PR filenames."
    );
  }

  return options;
}

function printHelpAndExit(): never {
  console.log(`Usage: bun run apps/www/scripts/pr-review-heatmap.ts [options] [file ...]

Options:
  --base <ref>          Base ref to diff against (default origin/main)
  --head <ref>          Head ref to diff (default HEAD)
  --model <model>       Model identifier for Vercel AI SDK
  --output <dir>        Directory for JSON artifacts (default tmp/pr-review-heatmap)
  --concurrency <n>     Max concurrent AI calls (default 50)
  --max-files <n>       Limit number of files processed
  --github-token <tok>  GitHub token for API requests (defaults to env vars)
  --github-api-base-url <url>  Override GitHub API base URL
  --use-gh-cli          Force using GitHub CLI for PR metadata & diffs
  --no-gh-cli           Disable GitHub CLI fallback even without a token
  --pr <url|id>         Pull request to analyze (uses GitHub API by default)
  --no-merge-base       Use two-dot diff instead of merge-base three-dot
  --help                Show this help message

Any positional arguments are treated as explicit file paths or filters to analyze.`);
  process.exit(0);
}

async function git(args: string[]): Promise<string> {
  const { stdout } = await execFileAsync("git", args, {
    cwd: process.cwd(),
    maxBuffer: 25 * 1024 * 1024,
  });
  return stdout;
}

async function resolveChangedFiles(
  diffRange: string,
  includePaths: string[]
): Promise<string[]> {
  if (includePaths.length > 0) {
    return includePaths;
  }
  const output = await git(["diff", "--name-only", diffRange]);
  return output
    .trim()
    .split("\n")
    .map((line) => line.trim())
    .filter((line) => line.length > 0);
}

async function readDiffForFile(
  diffRange: string,
  filePath: string
): Promise<string> {
  return git(["diff", diffRange, "--", filePath]);
}

async function collectLocalDiffs(
  diffRange: string,
  includePaths: string[],
  maxFiles: number | null
): Promise<FileDiff[]> {
  const allFiles = await resolveChangedFiles(diffRange, includePaths);
  if (allFiles.length === 0) {
    return [];
  }
  const files = maxFiles ? allFiles.slice(0, maxFiles) : allFiles;
  const results: FileDiff[] = [];
  let skippedBinary = 0;
  for (const filePath of files) {
    const diffText = await readDiffForFile(diffRange, filePath);
    if (!diffText || diffText.trim().length === 0) {
      continue;
    }
    if (isBinaryFile(filePath, diffText)) {
      skippedBinary += 1;
      console.log(`[heatmap] Skipping binary file: ${filePath}`);
      continue;
    }
    results.push({ filePath, diffText });
  }
  if (skippedBinary > 0) {
    console.log(`[heatmap] Skipped ${skippedBinary} binary file(s)`);
  }
  return results;
}

interface GhPrMetadata {
  owner: string;
  repo: string;
  number: number;
  prUrl: string;
  baseRefName: string;
  baseRefOid: string | null;
  headRefName: string;
  headRefOid: string | null;
  title: string | null;
}

function resolveGithubToken(token?: string | null): string | null {
  // If an explicit token is provided, use it
  if (token) {
    return token;
  }

  // Otherwise, try rotating tokens first
  const rotatingToken = getNextGitHubToken();
  if (rotatingToken) {
    return rotatingToken;
  }

  // Fall back to single token env vars
  return (
    process.env.GITHUB_TOKEN ??
    process.env.GH_TOKEN ??
    process.env.GITHUB_PERSONAL_ACCESS_TOKEN ??
    null
  );
}

function normalizeGithubApiBaseUrl(custom?: string): string {
  const base = (custom ?? DEFAULT_GITHUB_API_BASE_URL).trim();
  return base.endsWith("/") ? base : `${base}/`;
}

function buildGithubApiUrl(baseUrl: string, path: string): string {
  const normalizedPath = path.startsWith("/") ? path.slice(1) : path;
  return `${baseUrl}${normalizedPath}`;
}

function buildGithubHeaders(
  token: string | null,
  accept: string
): Record<string, string> {
  const headers: Record<string, string> = {
    Accept: accept,
    "User-Agent": GITHUB_USER_AGENT,
  };
  if (token) {
    headers.Authorization = `Bearer ${token}`;
  }
  return headers;
}

async function fetchGithubResponse(
  path: string,
  {
    token,
    baseUrl,
    accept,
    responseType,
  }: {
    token: string | null;
    baseUrl: string;
    accept: string;
    responseType: "json" | "text";
  }
): Promise<unknown> {
  const url = buildGithubApiUrl(baseUrl, path);
  const response = await fetch(url, {
    headers: buildGithubHeaders(token, accept),
    cache: "force-cache",
  });
  if (!response.ok) {
    const errorText = await response.text();
    throw new Error(
      `GitHub API request to ${url} failed with status ${response.status
      }: ${errorText.slice(0, 2000)}`
    );
  }
  return responseType === "json" ? response.json() : response.text();
}

interface ParsedPrIdentifier {
  owner: string;
  repo: string;
  number: number;
}

function parseGithubPrUrl(value: string): ParsedPrIdentifier {
  let url: URL;
  try {
    url = new URL(value);
  } catch (_error) {
    throw new Error(`Invalid PR URL: ${value}`);
  }
  const parts = url.pathname.split("/").filter(Boolean);
  if (parts.length < 4 || parts[2] !== "pull") {
    throw new Error(
      `PR URL must look like https://github.com/<owner>/<repo>/pull/<number>, received: ${value}`
    );
  }
  const number = Number(parts[3]);
  if (!Number.isInteger(number)) {
    throw new Error(`Invalid PR number in URL: ${value}`);
  }
  return { owner: parts[0], repo: parts[1], number };
}

function tryParseGithubPrUrl(value: string): ParsedPrIdentifier | null {
  try {
    return parseGithubPrUrl(value);
  } catch {
    return null;
  }
}

function parseGithubPrIdentifier(value: string): ParsedPrIdentifier {
  const fromUrl = tryParseGithubPrUrl(value);
  if (fromUrl) {
    return fromUrl;
  }
  const hashMatch = value.match(/^([^#]+)#(\d+)$/);
  if (hashMatch) {
    const repoParts = hashMatch[1].split("/");
    if (repoParts.length === 2) {
      const number = Number(hashMatch[2]);
      if (Number.isInteger(number)) {
        return {
          owner: repoParts[0],
          repo: repoParts[1],
          number,
        };
      }
    }
  }
  throw new Error(
    `PR identifier must be a GitHub URL or <owner>/<repo>#<number>, received: ${value}`
  );
}

interface GithubApiContext {
  token: string | null;
  baseUrl: string;
}

// Cache PR metadata to avoid rate limit exhaustion
// Cache entries expire after 5 minutes
const prMetadataCache = new Map<string, { metadata: GhPrMetadata; expiry: number }>();
const PR_METADATA_CACHE_TTL_MS = 5 * 60 * 1000; // 5 minutes

async function fetchPrMetadataFromGithub(
  identifier: ParsedPrIdentifier,
  context: GithubApiContext
): Promise<GhPrMetadata> {
  const cacheKey = `${identifier.owner}/${identifier.repo}#${identifier.number}`.toLowerCase();

  // Check cache first
  const cached = prMetadataCache.get(cacheKey);
  if (cached && cached.expiry > Date.now()) {
    return cached.metadata;
  }

  const path = `repos/${identifier.owner}/${identifier.repo}/pulls/${identifier.number}`;
  const data = (await fetchGithubResponse(path, {
    token: context.token,
    baseUrl: context.baseUrl,
    accept: "application/vnd.github+json",
    responseType: "json",
  })) as Record<string, unknown>;

  const base = (data.base as Record<string, unknown> | undefined) ?? undefined;
  const head = (data.head as Record<string, unknown> | undefined) ?? undefined;

  const prUrl =
    (typeof data.html_url === "string" && data.html_url.length > 0
      ? data.html_url
      : undefined) ??
    `https://github.com/${identifier.owner}/${identifier.repo}/pull/${identifier.number}`;

  const baseRefName =
    typeof base?.ref === "string" && base.ref.length > 0 ? base.ref : "unknown";
  const baseRefOid =
    typeof base?.sha === "string" && base.sha.length > 0 ? base.sha : null;
  const headRefName =
    typeof head?.ref === "string" && head.ref.length > 0 ? head.ref : "unknown";
  const headRefOid =
    typeof head?.sha === "string" && head.sha.length > 0 ? head.sha : null;

  const title =
    typeof data.title === "string" && data.title.length > 0 ? data.title : null;

  const metadata: GhPrMetadata = {
    owner: identifier.owner,
    repo: identifier.repo,
    number: identifier.number,
    prUrl,
    baseRefName,
    baseRefOid,
    headRefName,
    headRefOid,
    title,
  };

  // Cache the result
  prMetadataCache.set(cacheKey, {
    metadata,
    expiry: Date.now() + PR_METADATA_CACHE_TTL_MS,
  });

  return metadata;
}

function splitDiffIntoFiles(diffText: string): FileDiff[] {
  const lines = diffText.split("\n");
  const results: FileDiff[] = [];
  let currentFilePath: string | null = null;
  let currentBuffer: string[] = [];
  let skippedBinary = 0;

  const flushCurrent = (): void => {
    if (currentFilePath && currentBuffer.length > 0) {
      const content = currentBuffer.join("\n").trimEnd();
      if (content.length > 0) {
        if (isBinaryFile(currentFilePath, content)) {
          skippedBinary += 1;
          console.log(`[heatmap] Skipping binary file: ${currentFilePath}`);
        } else {
          results.push({ filePath: currentFilePath, diffText: content });
        }
      }
    }
    currentBuffer = [];
  };

  for (const line of lines) {
    if (line.startsWith("diff --git ")) {
      flushCurrent();
      const match = line.match(/^diff --git a\/(.+?) b\/(.+)$/);
      currentFilePath =
        match && typeof match[2] === "string"
          ? match[2]
          : `unknown_${results.length}`;
      currentBuffer = [line];
      continue;
    }
    if (currentBuffer.length === 0) {
      continue;
    }
    currentBuffer.push(line);
  }
  flushCurrent();

  if (skippedBinary > 0) {
    console.log(`[heatmap] Skipped ${skippedBinary} binary file(s) from PR`);
  }

  return results;
}

async function fetchPrDiffFromGithub(
  identifier: ParsedPrIdentifier,
  context: GithubApiContext
): Promise<FileDiff[]> {
  const path = `repos/${identifier.owner}/${identifier.repo}/pulls/${identifier.number}`;
  const diffText = (await fetchGithubResponse(path, {
    token: context.token,
    baseUrl: context.baseUrl,
    accept: "application/vnd.github.v3.diff",
    responseType: "text",
  })) as string;
  return splitDiffIntoFiles(diffText);
}

function filterFileDiffsByInclude(
  fileDiffs: FileDiff[],
  includePaths: string[]
): FileDiff[] {
  if (includePaths.length === 0) {
    return fileDiffs;
  }
  const includeSet = new Set(includePaths);
  return fileDiffs.filter((file) => includeSet.has(file.filePath));
}

export async function collectPrDiffs({
  prIdentifier,
  includePaths = [],
  maxFiles = null,
  githubToken,
  githubApiBaseUrl,
}: CollectPrDiffsOptions): Promise<{
  metadata: GhPrMetadata;
  fileDiffs: FileDiff[];
}> {
  const identifier = parseGithubPrIdentifier(prIdentifier);
  const token = resolveGithubToken(githubToken ?? null);
  const baseUrl = normalizeGithubApiBaseUrl(githubApiBaseUrl);
  const context: GithubApiContext = { token, baseUrl };
  const [metadata, allDiffs] = await Promise.all([
    fetchPrMetadataFromGithub(identifier, context),
    fetchPrDiffFromGithub(identifier, context),
  ]);
  let filtered = filterFileDiffsByInclude(allDiffs, includePaths ?? []);
  if (filtered.length === 0) {
    filtered = allDiffs;
  }
  const limited =
    typeof maxFiles === "number" && maxFiles > 0
      ? filtered.slice(0, maxFiles)
      : filtered;
  return { metadata, fileDiffs: limited };
}

interface GhCliSelection {
  argument: string;
  repo?: string;
  prUrlHint?: string;
}

function resolveGhCliSelection(input: string): GhCliSelection {
  const parsedFromUrl = tryParseGithubPrUrl(input);
  if (parsedFromUrl) {
    return {
      argument: String(parsedFromUrl.number),
      repo: `${parsedFromUrl.owner}/${parsedFromUrl.repo}`,
      prUrlHint: input,
    };
  }
  const hashMatch = input.match(/^([^#]+)#(\d+)$/);
  if (hashMatch) {
    return {
      argument: hashMatch[2],
      repo: hashMatch[1],
      prUrlHint: `https://github.com/${hashMatch[1]}/pull/${hashMatch[2]}`,
    };
  }
  return { argument: input };
}

async function runGhCommand(args: string[]): Promise<string> {
  const { stdout } = await execFileAsync("gh", args, {
    cwd: process.cwd(),
    maxBuffer: 50 * 1024 * 1024,
  });
  return stdout;
}

async function fetchPrMetadataViaGhCli(
  selection: GhCliSelection
): Promise<GhPrMetadata> {
  const fields = [
    "url",
    "number",
    "title",
    "baseRefName",
    "baseRefOid",
    "headRefName",
    "headRefOid",
  ];
  const args = ["pr", "view", selection.argument, "--json", fields.join(",")];
  if (selection.repo) {
    args.push("--repo", selection.repo);
  }
  const raw = await runGhCommand(args);
  const data = JSON.parse(raw) as Record<string, unknown>;

  const prUrl =
    (typeof data.url === "string" && data.url.length > 0
      ? data.url
      : selection.prUrlHint) ?? null;
  if (!prUrl) {
    throw new Error("gh pr view response did not include a PR URL.");
  }
  const parsed = parseGithubPrUrl(prUrl);

  return {
    owner: parsed.owner,
    repo: parsed.repo,
    number: parsed.number,
    prUrl,
    baseRefName:
      typeof data.baseRefName === "string" && data.baseRefName.length > 0
        ? data.baseRefName
        : "unknown",
    baseRefOid:
      typeof data.baseRefOid === "string" && data.baseRefOid.length > 0
        ? data.baseRefOid
        : null,
    headRefName:
      typeof data.headRefName === "string" && data.headRefName.length > 0
        ? data.headRefName
        : "unknown",
    headRefOid:
      typeof data.headRefOid === "string" && data.headRefOid.length > 0
        ? data.headRefOid
        : null,
    title:
      typeof data.title === "string" && data.title.length > 0
        ? data.title
        : null,
  };
}

async function fetchPrDiffViaGhCli(
  metadata: GhPrMetadata
): Promise<FileDiff[]> {
  const path = `repos/${metadata.owner}/${metadata.repo}/pulls/${metadata.number}`;
  const diffText = await runGhCommand([
    "api",
    path,
    "--header",
    "Accept: application/vnd.github.v3.diff",
  ]);
  return splitDiffIntoFiles(diffText);
}

async function collectPrDiffsViaGhCli(
  prIdentifier: string,
  includePaths: string[],
  maxFiles: number | null
): Promise<{
  metadata: GhPrMetadata;
  fileDiffs: FileDiff[];
}> {
  const selection = resolveGhCliSelection(prIdentifier);
  const metadata = await fetchPrMetadataViaGhCli(selection);
  const allDiffs = await fetchPrDiffViaGhCli(metadata);
  let filtered = filterFileDiffsByInclude(allDiffs, includePaths);
  if (filtered.length === 0) {
    filtered = allDiffs;
  }
  const limited = maxFiles ? filtered.slice(0, maxFiles) : filtered;
  return { metadata, fileDiffs: limited };
}

async function main(): Promise<void> {
  const scriptStartTime = Date.now();
  const options = parseCliArgs(process.argv.slice(2));

  const apiKey = process.env.OPENAI_API_KEY;
  if (!apiKey) {
    throw new Error("OPENAI_API_KEY environment variable is required.");
  }

  const absoluteOutputDir = resolvePath(process.cwd(), options.outputDir);
  await mkdir(absoluteOutputDir, { recursive: true });

  const openai = createOpenAI({ apiKey });
  const modelFactory = (modelId: string): LanguageModel => openai(modelId);

  let fileDiffs: FileDiff[] = [];
  let diffLabel = "";
  let prMetadata: GhPrMetadata | null = null;

  if (options.prIdentifier) {
    const resolvedToken = resolveGithubToken(options.githubToken);
    const shouldUseGhCliImmediately = options.preferGhCli;
    const allowGhCliFallback = options.allowGhCliFallback;

    let prData: {
      metadata: GhPrMetadata;
      fileDiffs: FileDiff[];
    } | null = null;

    if (!shouldUseGhCliImmediately) {
      try {
        prData = await collectPrDiffs({
          prIdentifier: options.prIdentifier,
          includePaths: options.includePaths,
          maxFiles: options.maxFiles,
          githubToken: resolvedToken,
          githubApiBaseUrl: options.githubApiBaseUrl ?? undefined,
        });
      } catch (error) {
        if (!allowGhCliFallback) {
          throw error;
        }
        const message =
          error instanceof Error
            ? error.message
            : String(error ?? "unknown error");
        console.warn(
          `[heatmap] GitHub API request failed (${message}); falling back to gh CLI...`
        );
      }
    }

    if (!prData) {
      if (!allowGhCliFallback) {
        throw new Error(
          "Failed to collect PR diffs via GitHub API and gh CLI fallback is disabled."
        );
      }
      console.log(
        `[heatmap] Fetching PR ${options.prIdentifier} via gh CLI fallback...`
      );
      prData = await collectPrDiffsViaGhCli(
        options.prIdentifier,
        options.includePaths,
        options.maxFiles
      );
    }

    prMetadata = prData.metadata;
    fileDiffs = prData.fileDiffs;
    diffLabel = `${prMetadata.owner}/${prMetadata.repo}#${prMetadata.number} (${prMetadata.baseRefName}...${prMetadata.headRefName})`;
  } else {
    const diffRange = options.useMergeBase
      ? `${options.baseRef}...${options.headRef}`
      : `${options.baseRef}..${options.headRef}`;
    diffLabel = diffRange;
    fileDiffs = await collectLocalDiffs(
      diffRange,
      options.includePaths,
      options.maxFiles
    );
  }

  if (fileDiffs.length === 0) {
    console.log("[heatmap] No diff content found to analyze.");
    return;
  }

  console.log(
    `[heatmap] Processing ${fileDiffs.length} file(s) with model ${options.model} [${diffLabel}]`
  );

  const jobResult = await runHeatmapJob({
    files: fileDiffs,
    concurrency: options.concurrency,
    modelId: options.model,
    modelFactory,
  });

  for (const result of jobResult.successes) {
    const markdown = formatResultAsMarkdown(
      result as HeatmapFileResult & { prompt: string; duration: number },
      options.model,
      diffLabel,
      prMetadata
    );
    const targetPath = join(
      absoluteOutputDir,
      `${sanitizeFilePath(result.filePath)}.md`
    );
    await writeFile(targetPath, markdown, "utf8");
    console.log(`[heatmap] Saved ${result.filePath} -> ${targetPath}`);
  }

  const summaryPath = join(absoluteOutputDir, "summary.json");
  await writeFile(
    summaryPath,
    `${JSON.stringify(
      {
        generatedAt: new Date().toISOString(),
        mode: prMetadata ? "github-pr" : "local-git",
        model: options.model,
        diffLabel,
        pr: prMetadata,
        filesAnalyzed: fileDiffs.length,
        successes: jobResult.successes.map((entry) => ({
          filePath: entry.filePath,
          lineCount: entry.lines.length,
        })),
        failures: jobResult.failures,
      },
      null,
      2
    )}\n`
  );

  console.log(
    `[heatmap] Completed with ${jobResult.successes.length} success(es) and ${jobResult.failures.length} failure(s). Summary saved to ${summaryPath}`
  );

  if (jobResult.failures.length > 0) {
    jobResult.failures.forEach((failure, index) => {
      console.error(
        `[heatmap] Failure ${index + 1} (${failure.filePath}): ${failure.message}`
      );
    });
    process.exitCode = 1;
  }

  // Print timing statistics
  const scriptDuration = Date.now() - scriptStartTime;
  console.log("");
  console.log("=== Timing Summary ===");
  console.log(`Total time: ${formatDuration(scriptDuration)}`);

  if (jobResult.successes.length > 0) {
    const durations = jobResult.successes.map(
      (s) => (s as HeatmapFileResult & { duration: number }).duration
    );
    const totalAnalysisTime = durations.reduce((a, b) => a + b, 0);
    const avgDuration = totalAnalysisTime / durations.length;
    const minDuration = Math.min(...durations);
    const maxDuration = Math.max(...durations);

    console.log(`Files analyzed: ${jobResult.successes.length}`);
    console.log(`Total analysis time: ${formatDuration(totalAnalysisTime)}`);
    console.log(`Average per file: ${formatDuration(avgDuration)}`);
    console.log(`Fastest: ${formatDuration(minDuration)}`);
    console.log(`Slowest: ${formatDuration(maxDuration)}`);

    // Show top 5 slowest files
    const sorted = [...jobResult.successes]
      .map((s) => ({
        filePath: s.filePath,
        duration: (s as HeatmapFileResult & { duration: number }).duration,
      }))
      .sort((a, b) => b.duration - a.duration);

    if (sorted.length > 1) {
      console.log("");
      console.log("Slowest files:");
      for (const item of sorted.slice(0, Math.min(5, sorted.length))) {
        console.log(`  ${formatDuration(item.duration)} - ${item.filePath}`);
      }
    }
  }
}

if (import.meta.main) {
  await main().catch((error) => {
    console.error(
      error instanceof Error ? (error.stack ?? error.message) : String(error)
    );
    process.exit(1);
  });
}
