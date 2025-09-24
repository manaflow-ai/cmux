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
const DEFAULT_BRANCH_TYPE: BranchType = "chore";
const DEFAULT_SCOPE = "general";
const DEFAULT_SLUG = "update-task";

const STOP_WORDS = new Set([
  "a",
  "an",
  "and",
  "are",
  "as",
  "be",
  "been",
  "before",
  "can",
  "could",
  "did",
  "do",
  "does",
  "for",
  "from",
  "had",
  "has",
  "have",
  "how",
  "in",
  "into",
  "is",
  "it",
  "once",
  "of",
  "on",
  "or",
  "over",
  "should",
  "than",
  "that",
  "the",
  "then",
  "these",
  "this",
  "those",
  "to",
  "under",
  "was",
  "were",
  "when",
  "where",
  "which",
  "while",
  "who",
  "why",
  "will",
  "with",
  "would",
]);

const SCOPE_AVOID = new Set([
  ...STOP_WORDS,
  "bug",
  "bugs",
  "change",
  "changes",
  "cleanup",
  "feature",
  "features",
  "fix",
  "issue",
  "issues",
  "task",
  "tasks",
  "typo",
  "typos",
  "update",
]);

const SCOPE_ALIASES = new Map<string, string>([
  ["authentication", "auth"],
  ["authorization", "authz"],
  ["config", "config"],
  ["configuration", "config"],
  ["database", "db"],
  ["dependencies", "deps"],
  ["dependency", "deps"],
  ["documentation", "docs"],
  ["frontend", "frontend"],
  ["backend", "backend"],
  ["infrastructure", "infra"],
  ["performance", "perf"],
  ["testing", "tests"],
  ["test", "tests"],
  ["analytics", "analytics"],
  ["payment", "payments"],
  ["payments", "payments"],
  ["user", "user"],
  ["users", "user"],
  ["api", "api"],
  ["apis", "api"],
]);

interface BranchComponents {
  type: BranchType;
  scope: string;
  slug: string;
}

function wordsFromText(text: string): string[] {
  return text
    .toLowerCase()
    .match(/[a-z0-9]+/g) ?? [];
}

function inferTypeFromSummary(words: string[]): BranchType {
  if (!words.length) {
    return DEFAULT_BRANCH_TYPE;
  }

  const first = words[0];
  const keywordTypeMap: Record<BranchType, string[]> = {
    feat: [
      "add",
      "create",
      "implement",
      "introduce",
      "enable",
      "allow",
      "support",
      "provide",
      "build",
      "ship",
    ],
    fix: [
      "fix",
      "patch",
      "resolve",
      "repair",
      "address",
      "correct",
    ],
    chore: [
      "update",
      "upgrade",
      "bump",
      "sync",
      "align",
      "configure",
      "cleanup",
      "tidy",
      "remove",
      "rename",
      "deprecate",
    ],
    refactor: [
      "refactor",
      "restructure",
      "simplify",
      "rework",
      "rewrite",
      "modularize",
      "split",
      "extract",
      "migrate",
    ],
    docs: [
      "document",
      "docs",
      "write",
      "update-docs",
      "clarify",
      "explain",
    ],
    test: ["test", "cover", "verify", "assert", "ensure"],
    perf: ["optimize", "improve", "speed", "tune", "profile"],
    build: ["package", "bundle", "compile"],
    ci: ["ci", "pipeline", "workflow", "lint"],
    revert: ["revert", "rollback", "undo"],
    spike: ["spike", "investigate", "explore", "prototype"],
  };

  for (const [type, keywords] of Object.entries(keywordTypeMap) as [
    BranchType,
    string[]
  ][]) {
    if (keywords.includes(first)) {
      return type;
    }
  }

  return DEFAULT_BRANCH_TYPE;
}

function sanitizeScopeTokens(tokens: string[]): string {
  if (!tokens.length) {
    return DEFAULT_SCOPE;
  }

  const normalized = tokens
    .map(token => SCOPE_ALIASES.get(token) ?? token)
    .filter(Boolean);

  if (!normalized.length) {
    return DEFAULT_SCOPE;
  }

  return normalized.slice(0, 2).join("-");
}

function inferScope(explicitScope: string | undefined, words: string[]): string {
  if (explicitScope) {
    const scopeWords = wordsFromText(explicitScope);
    return sanitizeScopeTokens(scopeWords);
  }

  const scopeCandidates = words
    .slice(1)
    .filter(word => !STOP_WORDS.has(word) && !SCOPE_AVOID.has(word));

  return sanitizeScopeTokens(scopeCandidates);
}

function buildSlug(words: string[]): string {
  if (!words.length) {
    return DEFAULT_SLUG;
  }

  let baseWords = [...words];
  while (baseWords.length > 1 && STOP_WORDS.has(baseWords[0])) {
    baseWords = baseWords.slice(1);
  }

  const filtered = baseWords.filter(
    (word, index) => index === 0 || !STOP_WORDS.has(word)
  );
  const chosen = (filtered.length ? filtered : baseWords).slice(0, 6);
  const slug = toKebabCase(chosen.join(" "));
  return slug || DEFAULT_SLUG;
}

function extractTypeFromHead(head: string, summaryWords: string[]): BranchType {
  const match = head.match(/^(?<type>[a-z]+)(?:\([^)]+\))?$/i);
  const typeCandidate = match?.groups?.type?.toLowerCase();

  if (typeCandidate && BRANCH_TYPE_SET.has(typeCandidate as BranchType)) {
    return typeCandidate as BranchType;
  }

  return inferTypeFromSummary(summaryWords);
}

function extractScopeFromHead(head: string): string | undefined {
  const match = head.match(/^[a-z]+\((?<scope>[^)]+)\)$/i);
  return match?.groups?.scope;
}

function parseSummaryFromTitle(prTitle: string): {
  head: string;
  summary: string;
} {
  const trimmed = prTitle.trim();
  const colonIndex = trimmed.indexOf(":");

  if (colonIndex === -1) {
    return { head: "", summary: trimmed };
  }

  const head = trimmed.slice(0, colonIndex).trim();
  let summary = trimmed.slice(colonIndex + 1).trim();

  summary = summary.replace(/\s*\((?:#[^)]+|[A-Z]{2,10}-\d+)\)\s*$/, "");
  summary = summary.replace(/\s*\[[^\]]+\]\s*$/, "");

  return { head, summary: summary || trimmed.slice(colonIndex + 1).trim() };
}

function deriveBranchComponentsFromWords(words: string[]): BranchComponents {
  const safeWords = words.length ? words : wordsFromText(DEFAULT_SLUG);
  const type = inferTypeFromSummary(safeWords);
  const scope = inferScope(undefined, safeWords);
  const slug = buildSlug(safeWords);
  return { type, scope, slug };
}

function deriveBranchComponentsFromText(text: string): BranchComponents {
  const words = wordsFromText(text);
  return deriveBranchComponentsFromWords(words);
}

function extractBranchComponentsFromTitle(prTitle: string): BranchComponents {
  const trimmed = prTitle.trim();

  if (!trimmed) {
    return deriveBranchComponentsFromText(trimmed);
  }

  const { head, summary } = parseSummaryFromTitle(trimmed);
  const summaryWords = wordsFromText(summary);
  const fallbackWords = summaryWords.length ? summaryWords : wordsFromText(trimmed);
  const type = extractTypeFromHead(head, fallbackWords);
  const scope = inferScope(extractScopeFromHead(head), fallbackWords);
  const slug = buildSlug(fallbackWords);
  return { type, scope, slug };
}

const BRANCH_PATH_REGEX = new RegExp(
  `^(?:${BRANCH_TYPES.join("|")})\/[a-z0-9][a-z0-9-]*\/[a-z0-9][a-z0-9-]*(?:-[a-z0-9][a-z0-9-]*){0,5}$`
);

function capitalize(word: string): string {
  if (!word) {
    return word;
  }
  return word.charAt(0).toUpperCase() + word.slice(1);
}

function buildTitleSummary(
  words: string[],
  maxLength: number,
  prefixLength: number
): string {
  let candidateWords = words.length ? [...words] : wordsFromText(DEFAULT_SLUG);

  while (candidateWords.length > 1 && STOP_WORDS.has(candidateWords[0])) {
    candidateWords = candidateWords.slice(1);
  }

  const filtered = candidateWords.filter(
    (word, index) => index === 0 || !STOP_WORDS.has(word)
  );
  let selected = (filtered.length ? filtered : candidateWords).slice(0, 8);
  if (!selected.length) {
    selected = DEFAULT_SLUG.split("-");
  }

  const toSummary = (list: string[]) =>
    list.map((word, index) => (index === 0 ? capitalize(word) : word)).join(" ");

  let summary = toSummary(selected).replace(/\.$/, "");
  while (summary.length + prefixLength > maxLength && selected.length > 1) {
    selected = selected.slice(0, -1);
    summary = toSummary(selected).replace(/\.$/, "");
  }

  if (summary.length + prefixLength > maxLength) {
    summary = summary.slice(0, Math.max(0, maxLength - prefixLength)).trimEnd();
  }

  return summary || capitalize(DEFAULT_SLUG.replace(/-/g, " "));
}

function branchPathToComponents(branchPath: string): BranchComponents {
  const cleaned = branchPath.trim().replace(/^cmux\//, "");
  const segments = cleaned.split("/").filter(Boolean);

  if (segments.length >= 3) {
    const [typeSegment, scopeSegment, ...slugSegments] = segments;
    const type = BRANCH_TYPE_SET.has(typeSegment as BranchType)
      ? (typeSegment as BranchType)
      : DEFAULT_BRANCH_TYPE;
    const scope = sanitizeScopeTokens(wordsFromText(scopeSegment));
    const slug = buildSlug(wordsFromText(slugSegments.join(" ")));
    return { type, scope, slug };
  }

  return deriveBranchComponentsFromText(branchPath);
}

function normalizeBranchPath(branchPath: string): string {
  const cleaned = branchPath.trim().replace(/^cmux\//, "");
  if (BRANCH_PATH_REGEX.test(cleaned)) {
    return cleaned;
  }
  const { type, scope, slug } = branchPathToComponents(cleaned);
  return `${type}/${scope}/${slug}`;
}

function normalizePrTitle(
  prTitle: string,
  components: BranchComponents
): string {
  const prefix = `${components.type}(${components.scope}): `;
  const summary = buildTitleSummary(
    wordsFromText(prTitle),
    72,
    prefix.length
  );
  return `${prefix}${summary}`;
}

/**
 * Generate a branch name from a PR title
 * @param prTitle The PR title to convert to a branch name
 * @returns A branch name in the format cmux/<type>/<scope>/<slug>-<random>
 */
export function generateBranchName(prTitle: string): string {
  const { type, scope, slug } = extractBranchComponentsFromTitle(prTitle);
  const randomId = generateRandomId();
  return `cmux/${type}/${scope}/${slug}-${randomId}`;
}

const prGenerationSchema = z.object({
  branchName: z
    .string()
    .transform((value) => value.trim())
    .transform((value) => value.replace(/^cmux\//, ""))
    .refine((value) => BRANCH_PATH_REGEX.test(value), {
      message:
        "Branch name must follow <type>/<scope>/<slug> using lowercase letters, numbers, and hyphens.",
    })
    .describe(
      "Branch path after the 'cmux/' prefix. Format: <type>/<scope>/<short-imperative-slug>. " +
        "Use lowercase letters, keep the total length reasonable (≤60 chars), and avoid personal names, dates, or environments. " +
        "<type> must be one of feat, fix, chore, refactor, docs, test, perf, build, ci, revert, spike. " +
        "<scope> should be a stable area name with 1–2 hyphenated tokens. " +
        "<short-imperative-slug> should be 2–6 imperative words separated by hyphens. " +
        "Do not include the 'cmux/' prefix or the random '-abcde' suffix; the system adds them."
    ),
  prTitle: z
    .string()
    .transform((value) => value.trim())
    .transform((value) => value.replace(/\.$/, ""))
    .refine((value) => value.length > 0 && value.length <= 72, {
      message: "PR title must be 1-72 characters with no trailing period.",
    })
    .describe(
      "PR title in the format <type>(<scope>): <imperative summary> [<issue>]. " +
        "Use present-tense imperative verbs, avoid emojis, and mirror the branch scope when possible."
    ),
});

type PRGeneration = z.infer<typeof prGenerationSchema>;

function createFallbackPRInfo(taskDescription: string): PRGeneration {
  const words = wordsFromText(taskDescription);
  const components = deriveBranchComponentsFromWords(words);
  const prefix = `${components.type}(${components.scope}): `;
  const summary = buildTitleSummary(words, 72, prefix.length);
  return {
    branchName: `${components.type}/${components.scope}/${components.slug}`,
    prTitle: `${prefix}${summary}`,
  };
}

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
  const systemPrompt = `You are a helpful assistant that generates git branch paths (without the "cmux/" prefix) and PR titles that follow cmux conventions.

Branch names:
- Return only the branch path that comes after the "cmux/" prefix; the system will prepend "cmux/" and append a random "-abcde" suffix for uniqueness.
- Format: <type>/<scope>/<short-imperative-slug>
  * <type>: feat, fix, chore, refactor, docs, test, perf, build, ci, revert, spike.
  * <scope>: stable area name (service, package, feature) using 1–2 lowercase tokens joined by hyphens.
  * <short-imperative-slug>: 2–6 lowercase imperative tokens joined by hyphens. Avoid stopwords when possible.
- Use lowercase letters and numbers, keep total length ≤ 60 chars, and avoid personal names, dates, or environment names.
- Use spike/<scope>/<slug> for short-lived experiments. Use release/<x.y.z> or hotfix/<x.y.z>-<slug> only when the task explicitly calls for them.

Branch titles:
- Format: <type>(<scope>): <imperative summary> [<issue>]
- Use present-tense imperative verbs, keep the title ≤ 72 characters, and do not add a trailing period or emoji.
- Mirror the branch scope when possible and put tracker IDs at the end in parentheses (e.g., (PAY-123) or (#8810)).

Examples:
Task: Add webhook signing to payments (PAY-123)
branchName: feat/payments/add-webhook-signing
prTitle: feat(payments): add webhook signing (PAY-123)

Task: Fix expired refresh tokens bug #8810
branchName: fix/auth/renew-expired-refresh-tokens
prTitle: fix(auth): renew expired refresh tokens (#8810)

Task: Simplify layout grid in app shell
branchName: refactor/app-shell/simplify-layout-grid
prTitle: refactor(app-shell): simplify layout grid

Return concise, high-signal results that strictly follow the schema.`;
  const userPrompt = `Task: ${taskDescription}`;

  const modelConfig = getModelAndProvider(apiKeys);
  const fallbackInfo = createFallbackPRInfo(taskDescription);

  if (!modelConfig) {
    serverLogger.warn(
      "[BranchNameGenerator] No API keys available, using fallback"
    );
    return fallbackInfo;
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

    const branchPath = normalizeBranchPath(object.branchName);
    const components = branchPathToComponents(branchPath);
    const prTitle = normalizePrTitle(object.prTitle, components);
    const result: PRGeneration = {
      branchName: branchPath,
      prTitle,
    };
    serverLogger.info(
      `[BranchNameGenerator] Generated via ${providerName}: branch="${result.branchName}", title="${result.prTitle}"`
    );
    return result;
  } catch (error) {
    serverLogger.error(
      `[BranchNameGenerator] ${providerName} API error:`,
      error
    );

    return fallbackInfo;
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
  return result ? result.prTitle : null;
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
  const fallbackInfo = createFallbackPRInfo(taskDescription);
  const branchPath = result?.branchName ?? fallbackInfo.branchName;
  return `cmux/${normalizeBranchPath(branchPath)}`;
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
  const fallbackInfo = createFallbackPRInfo(taskDescription);
  return prTitle ?? fallbackInfo.prTitle;
}

/**
 * Generate multiple unique branch names given a PR title
 */
export function generateUniqueBranchNamesFromTitle(
  prTitle: string,
  count: number
): string[] {
  const { type, scope, slug } = extractBranchComponentsFromTitle(prTitle);
  const baseName = `cmux/${type}/${scope}/${slug}`;
  const ids = new Set<string>();
  while (ids.size < count) ids.add(generateRandomId());
  return Array.from(ids).map((id) => `${baseName}-${id}`);
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
  return `${baseName}-${id}`;
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

  // Generate unique IDs
  const ids = new Set<string>();
  while (ids.size < count) {
    ids.add(generateRandomId());
  }

  return Array.from(ids).map((id) => `${baseName}-${id}`);
}
