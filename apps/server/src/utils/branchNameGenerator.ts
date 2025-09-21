import { createAnthropic } from "@ai-sdk/anthropic";
import { createGoogleGenerativeAI } from "@ai-sdk/google";
import { createOpenAI } from "@ai-sdk/openai";
import { api } from "@cmux/convex/api";
import { generateObject, type LanguageModel } from "ai";
import { z } from "zod";
import { getConvex } from "../utils/convexClient.js";
import { serverLogger } from "./fileLogger.js";

/**
 * Convert a string to kebab case and filter out suspicious characters
 * @param input The input string to convert
 * @returns The kebab-cased string with only safe characters
 */
export function toKebabCase(input: string): string {
  return (
    input
      // Treat pluralized acronyms like "PRs"/"APIs"/"IDs" as single tokens
      // - If a word starts with 2+ capitals followed by a lone lowercase 's',
      //   optionally followed by another capitalized sequence, keep the 's' with the acronym
      //   so we don't insert a hyphen inside it (e.g., "PRs" -> "PRS", "PRsFix" -> "PRSFix").
      .replace(/\b([A-Z]{2,})s(?=\b|[^a-z])/g, "$1S")
      // First, handle camelCase by inserting hyphens before capital letters
      .replace(/([a-z])([A-Z])/g, "$1-$2")
      // Also handle sequences like "HTTPServer" -> "HTTP-Server"
      .replace(/([A-Z])([A-Z][a-z])/g, "$1-$2")
      .toLowerCase()
      // Replace any sequence of non-alphanumeric characters with a single hyphen
      .replace(/[^a-z0-9]+/g, "-")
      // Remove leading and trailing hyphens
      .replace(/^-+|-+$/g, "")
      // Replace multiple consecutive hyphens with a single hyphen (including --)
      .replace(/-{2,}/g, "-")
      // Limit length to 50 characters
      .substring(0, 50)
  );
}

/**
 * Generate a random 5-character alphanumeric string
 * @returns A 5-character string [a-z0-9]
 */
export function generateRandomId(): string {
  const chars = "abcdefghijklmnopqrstuvwxyz0123456789";
  let result = "";
  for (let i = 0; i < 5; i++) {
    result += chars.charAt(Math.floor(Math.random() * chars.length));
  }
  return result;
}

const BRANCH_TYPES = [
  "feat",
  "fix",
  "chore",
  "refactor",
  "docs",
  "test",
  "perf",
  "build",
  "ci",
  "revert",
  "spike",
] as const;

type BranchType = (typeof BRANCH_TYPES)[number];

const BRANCH_TYPE_SET = new Set<BranchType>(BRANCH_TYPES);

interface BranchComponents {
  type: BranchType;
  scope: string;
  slug: string;
  issue?: string;
}

function stripCmuxPrefix(value: string): string {
  return value.replace(/^cmux\//i, "");
}

function normalizeBranchType(type?: string): BranchType {
  const normalized = (type ?? "").toLowerCase() as BranchType;
  return BRANCH_TYPE_SET.has(normalized) ? normalized : "chore";
}

function sanitizeScope(scope?: string): string {
  const sanitized = toKebabCase(scope ?? "");
  return sanitized || "general";
}

function sanitizeSlug(slug?: string): string {
  const sanitized = toKebabCase(slug ?? "");
  return sanitized || "update";
}

function sanitizeIssue(issue?: string): string | undefined {
  if (!issue) {
    return undefined;
  }

  const normalized = issue
    .trim()
    .replace(/^[#\s]+/, "")
    .replace(/\s+/g, "-")
    .replace(/[^A-Za-z0-9-]/g, "");

  if (!normalized) {
    return undefined;
  }

  const candidate = normalized.toUpperCase();

  if (/^\d+$/.test(candidate)) {
    return candidate;
  }

  if (/^[A-Z]{2,10}-\d+$/.test(candidate)) {
    return candidate;
  }

  return undefined;
}

function buildBranchName({ type, scope, slug, issue }: BranchComponents): string {
  const base = `${type}/${scope}/${slug}`;
  return issue ? `${base}-${issue}` : base;
}

function deriveScopeFromWords(words: string[]): string {
  return sanitizeScope(words.slice(0, 2).join(" "));
}

function deriveFallbackComponentsFromWords(words: string[]): BranchComponents {
  if (words.length === 0) {
    return { type: "chore", scope: "general", slug: "update" };
  }

  const firstWord = words[0]?.toLowerCase() ?? "";
  let type: BranchType = "chore";
  let remainingWords = words;

  if (BRANCH_TYPE_SET.has(firstWord as BranchType)) {
    type = firstWord as BranchType;
    remainingWords = words.slice(1);
  }

  if (remainingWords.length === 0) {
    remainingWords = words;
  }

  const scope = deriveScopeFromWords(remainingWords);
  const slug = sanitizeSlug(remainingWords.join(" "));

  return { type, scope, slug };
}

function extractSummaryAndIssue(rawSummary: string): {
  summary: string;
  issue?: string;
} {
  let summary = rawSummary.trim();

  if (!summary) {
    return { summary: "" };
  }

  const issueMatch = summary.match(
    /(?:\(|\[)\s*(#?[A-Za-z]{2,10}-\d+|#?\d+)\s*(?:\)|\])\s*$/,
  );

  if (issueMatch && typeof issueMatch.index === "number") {
    const issue = sanitizeIssue(issueMatch[1]);
    if (issue) {
      summary = summary.slice(0, issueMatch.index).trim();
      return { summary, issue };
    }
  }

  return { summary };
}

function normalizeBranchName(rawBranchName: string): BranchComponents {
  const trimmed = stripCmuxPrefix(rawBranchName.trim());

  if (!trimmed) {
    return { type: "chore", scope: "general", slug: "update" };
  }

  const segments = trimmed.split("/");

  if (segments.length >= 3) {
    const [typeSegment, scopeSegment, ...slugSegments] = segments;
    let slugPart = slugSegments.join("-");
    let issue: string | undefined;

    const issueMatch = slugPart.match(/-(?<issue>(?:[A-Z]{2,10}-\d+|\d+))$/);
    if (issueMatch?.groups?.issue) {
      const maybeIssue = sanitizeIssue(issueMatch.groups.issue);
      if (maybeIssue) {
        issue = maybeIssue;
        slugPart = slugPart.slice(0, slugPart.length - issueMatch[0]!.length);
      }
    }

    const type = normalizeBranchType(typeSegment);
    const scope = sanitizeScope(scopeSegment);
    const slug = sanitizeSlug(slugPart);

    return { type, scope, slug, issue };
  }

  const { summary, issue } = extractSummaryAndIssue(trimmed);
  const fallbackWords = summary
    .replace(/[\/]+/g, " ")
    .split(/\s+/)
    .filter(Boolean);
  const components = deriveFallbackComponentsFromWords(fallbackWords);

  return issue ? { ...components, issue } : components;
}

function parseBranchComponentsFromPRTitle(prTitle: string): BranchComponents {
  const trimmed = prTitle.trim();
  const colonIndex = trimmed.indexOf(":");

  let typeScopePart = "";
  let remainder = trimmed;

  if (colonIndex !== -1) {
    typeScopePart = trimmed.slice(0, colonIndex);
    remainder = trimmed.slice(colonIndex + 1);
  }

  const typeScopeMatch = typeScopePart
    .trim()
    .match(/^(?<type>[a-z]+)(?:\((?<scope>[^)]+)\))?$/i);

  const { summary, issue } = extractSummaryAndIssue(
    remainder.trim() || trimmed,
  );

  const summaryWords = summary.split(/\s+/).filter(Boolean);

  let type = normalizeBranchType(typeScopeMatch?.groups?.type);
  let scope = sanitizeScope(typeScopeMatch?.groups?.scope);

  if (!typeScopeMatch) {
    type = "chore";
  }

  if (!typeScopeMatch?.groups?.scope) {
    scope = deriveScopeFromWords(summaryWords.length > 0 ? summaryWords : [trimmed]);
  }

  const slugSource = summary || remainder || trimmed;
  const slug = sanitizeSlug(slugSource);

  return { type, scope, slug, issue };
}

function deriveFallbackData(taskDescription: string): {
  components: BranchComponents;
  summary: string;
} {
  const words = taskDescription.split(/\s+/).filter(Boolean);
  const scope = deriveScopeFromWords(words);
  const slug = sanitizeSlug(words.join(" "));
  const summary = words.slice(0, 8).join(" ") || "update task";

  return {
    components: { type: "chore", scope, slug },
    summary,
  };
}

/**
 * Generate a branch name from a PR title using the prescribed format
 * @param prTitle The PR title to convert to a branch name
 * @returns A branch name in the format <type>/<scope>/<slug>[-<issue>]
 */
export function generateBranchName(prTitle: string): string {
  const components = parseBranchComponentsFromPRTitle(prTitle);
  return buildBranchName(components);
}

const prGenerationSchema = z.object({
  branchName: z
    .string()
    .describe(
      "A git branch name that follows <type>/<scope>/<short-imperative-slug>[-<issue>]"
    ),
  prTitle: z
    .string()
    .describe(
      "A PR title using <type>(<scope>): <imperative summary> [<issue>]"
    ),
});

type PRGeneration = z.infer<typeof prGenerationSchema>;

/**
 * Get the appropriate AI model and provider name based on available API keys
 * @param apiKeys Map of API keys
 * @returns Object with model and provider name, or null if no keys available
 */
function getModelAndProvider(
  apiKeys: Record<string, string>
): { model: LanguageModel; providerName: string } | null {
  if (apiKeys.OPENAI_API_KEY) {
    const openai = createOpenAI({
      apiKey: apiKeys.OPENAI_API_KEY,
    });
    return {
      model: openai("gpt-5-nano"),
      providerName: "OpenAI",
    };
  }

  if (apiKeys.GEMINI_API_KEY) {
    const google = createGoogleGenerativeAI({
      apiKey: apiKeys.GEMINI_API_KEY,
    });
    return {
      model: google("gemini-2.5-flash"),
      providerName: "Gemini",
    };
  }

  if (apiKeys.ANTHROPIC_API_KEY) {
    const anthropic = createAnthropic({
      apiKey: apiKeys.ANTHROPIC_API_KEY,
    });
    return {
      model: anthropic("claude-3-5-haiku-20241022"),
      providerName: "Anthropic",
    };
  }

  return null;
}

/**
 * Generate both a branch name and PR title from a task description
 * @param taskDescription The task description
 * @param apiKeys Map of API keys
 * @returns Object with branch name and PR title, or null if no API keys available
 */
export async function generatePRInfo(
  taskDescription: string,
  apiKeys: Record<string, string>
): Promise<PRGeneration | null> {
  const systemPrompt = `You are a helpful assistant that generates git branch names and PR titles.

Follow these branch name rules exactly:
- Format: <type>/<scope>/<short-imperative-slug>[-<issue>]
- Lowercase only. Use hyphens for words; separate segments with slashes.
- Keep total length reasonable (aim ≤ 60 chars).
- <type> must be one of: feat, fix, chore, refactor, docs, test, perf, build, ci, revert, spike.
- <scope> is a stable area name (1–2 tokens) such as payments, auth, app-shell.
- <short-imperative-slug> uses 2–6 imperative words, avoiding stopwords when possible.
- Optional issue suffix is -1234 or -PAY-123 and should match the team's tracker format if provided.
- Do not include personal names, dates, environment names, or words like wip.

Special cases:
- Long-lived branches stay as main or release/<x.y.z>.
- Hotfixes use hotfix/<x.y.z>-<slug>.
- Spikes use spike/<scope>/<slug>.

Branch name examples:
- feat/payments/add-webhook-signing-PAY-123
- fix/auth/renew-expired-refresh-tokens-8810
- refactor/app-shell/simplify-layout-grid
- docs/infra/rotate-aws-keys

Anti-examples (never produce these patterns):
- newbranch
- Feature/Add_Stuff
- fix/typo-in-readme.
- johns-work
- tickets/123

Pull request title rules:
- Format: <type>(<scope>): <imperative summary> [<issue>]
- Keep ≤ 72 characters, imperative mood, no trailing period, no emoji.
- Scope should mirror the branch scope when possible.

PR title examples:
- feat(payments): add webhook signing (PAY-123)
- fix(auth): renew expired refresh tokens (#8810)
- refactor(app-shell): simplify layout grid
- docs(infra): document AWS key rotation

Return concise, professional outputs that fit the task.`;
  const userPrompt = `Task: ${taskDescription}`;

  const modelConfig = getModelAndProvider(apiKeys);

  if (!modelConfig) {
    serverLogger.warn(
      "[BranchNameGenerator] No API keys available, using fallback"
    );
    const fallback = deriveFallbackData(taskDescription);
    return {
      branchName: buildBranchName(fallback.components),
      prTitle: `${fallback.components.type}(${fallback.components.scope}): ${fallback.summary}`,
    };
  }

  const { model, providerName } = modelConfig;

  try {
    const { object } = await generateObject({
      model,
      schema: prGenerationSchema,
      system: systemPrompt,
      prompt: userPrompt,
      maxRetries: 2,
      temperature: 0.3,
    });

    const sanitizedBranchName = buildBranchName(
      normalizeBranchName(object.branchName)
    );
    const prTitleCandidate = object.prTitle?.trim();
    let finalTitle: string;
    if (prTitleCandidate && prTitleCandidate.length > 0) {
      finalTitle = prTitleCandidate;
    } else {
      const fallbackData = deriveFallbackData(taskDescription);
      finalTitle = `${fallbackData.components.type}(${fallbackData.components.scope}): ${fallbackData.summary}`;
    }

    serverLogger.info(
      `[BranchNameGenerator] Generated via ${providerName}: branch="${sanitizedBranchName}", title="${finalTitle}"`
    );
    return { branchName: sanitizedBranchName, prTitle: finalTitle };
  } catch (error) {
    serverLogger.error(
      `[BranchNameGenerator] ${providerName} API error:`,
      error
    );

    const fallback = deriveFallbackData(taskDescription);
    return {
      branchName: buildBranchName(fallback.components),
      prTitle: `${fallback.components.type}(${fallback.components.scope}): ${fallback.summary}`,
    };
  }
}

/**
 * Call an LLM to generate a PR title from a task description
 * @param taskDescription The task description
 * @param apiKeys Map of API keys
 * @returns The generated PR title or null if no API keys available
 */
export async function generatePRTitle(
  taskDescription: string,
  apiKeys: Record<string, string>
): Promise<string | null> {
  const result = await generatePRInfo(taskDescription, apiKeys);
  if (result?.prTitle) {
    return result.prTitle;
  }

  const fallback = deriveFallbackData(taskDescription);
  return `${fallback.components.type}(${fallback.components.scope}): ${fallback.summary}`;
}

/**
 * Generate a base name for branches (without the unique ID)
 * @param taskDescription The task description
 * @returns The base branch name without ID
 */
export async function generateBranchBaseName(
  taskDescription: string,
  teamSlugOrId: string
): Promise<string> {
  // Fetch API keys from Convex
  const apiKeys = await getConvex().query(api.apiKeys.getAllForAgents, {
    teamSlugOrId,
  });

  const result = await generatePRInfo(taskDescription, apiKeys);
  if (result?.branchName) {
    return buildBranchName(normalizeBranchName(result.branchName));
  }

  const fallback = deriveFallbackData(taskDescription);
  return buildBranchName(fallback.components);
}

/**
 * Get a PR title for a given task description using available API keys.
 * Falls back to a simple 5-word prefix of the task description.
 */
export async function getPRTitleFromTaskDescription(
  taskDescription: string,
  teamSlugOrId: string
): Promise<string> {
  const apiKeys = await getConvex().query(api.apiKeys.getAllForAgents, {
    teamSlugOrId,
  });
  const prTitle = await generatePRTitle(taskDescription, apiKeys);
  if (prTitle) {
    return prTitle;
  }

  const fallback = deriveFallbackData(taskDescription);
  return `${fallback.components.type}(${fallback.components.scope}): ${fallback.summary}`;
}

/**
 * Generate multiple unique branch names given a PR title
 */
export function generateUniqueBranchNamesFromTitle(
  prTitle: string,
  count: number
): string[] {
  const components = parseBranchComponentsFromPRTitle(prTitle);
  const ids = new Set<string>();
  while (ids.size < count) ids.add(generateRandomId());
  return Array.from(ids).map((id) =>
    buildBranchName({
      ...components,
      slug: `${components.slug}-${id}`,
    })
  );
}

/**
 * Export the PR generation schema and type for testing
 */
export { prGenerationSchema, type PRGeneration };

/**
 * Generate a new branch name for a task run with a specific ID
 * @param taskDescription The task description
 * @param uniqueId Optional unique ID to use (if not provided, generates one)
 * @returns The generated branch name
 */
export async function generateNewBranchName(
  taskDescription: string,
  teamSlugOrId: string,
  uniqueId?: string
): Promise<string> {
  const baseName = await generateBranchBaseName(taskDescription, teamSlugOrId);
  const id = uniqueId || generateRandomId();
  const components = normalizeBranchName(baseName);
  return buildBranchName({
    ...components,
    slug: `${components.slug}-${id}`,
  });
}

/**
 * Generate multiple unique branch names at once
 * @param taskDescription The task description
 * @param count Number of branch names to generate
 * @returns Array of unique branch names
 */
export async function generateUniqueBranchNames(
  taskDescription: string,
  count: number,
  teamSlugOrId: string
): Promise<string[]> {
  const baseName = await generateBranchBaseName(taskDescription, teamSlugOrId);
  const baseComponents = normalizeBranchName(baseName);

  // Generate unique IDs
  const ids = new Set<string>();
  while (ids.size < count) {
    ids.add(generateRandomId());
  }

  return Array.from(ids).map((id) =>
    buildBranchName({
      ...baseComponents,
      slug: `${baseComponents.slug}-${id}`,
    })
  );
}
