import { createAnthropic } from "@ai-sdk/anthropic";
import { createGoogleGenerativeAI } from "@ai-sdk/google";
import { createOpenAI } from "@ai-sdk/openai";
import { api } from "@cmux/convex/api";
import { generateObject, type LanguageModel } from "ai";
import { z } from "zod";
import { getConvex } from "../utils/convexClient.js";
import { serverLogger } from "./fileLogger.js";

const DEFAULT_BRANCH_TYPE = "chore";
const DEFAULT_BRANCH_SCOPE = "general";

function buildDefaultBranchPath(source: string): string {
  const slug = toKebabCase(source);
  const safeSlug = slug.length > 0 ? slug : "update";
  return `${DEFAULT_BRANCH_TYPE}/${DEFAULT_BRANCH_SCOPE}/${safeSlug}`;
}

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

/**
 * Generate a branch name from a PR title
 * @param prTitle The PR title to convert to a branch name
 * @returns A branch name in the format cmux/feature-name-xxxx
 */
export function generateBranchName(prTitle: string): string {
  const basePath = buildDefaultBranchPath(prTitle);
  const randomId = generateRandomId();
  return `cmux/${basePath}-${randomId}`;
}

const prGenerationSchema = z.object({
  branchName: z
    .string()
    .describe(
      "Branch path without the 'cmux/' prefix that follows <type>/<scope>/<short-imperative-slug>[-<issue>] with lowercase, hyphenated words. Keep scope to 1-2 tokens, use 2-6 imperative words for the slug, and never append random IDs."
    ),
  prTitle: z
    .string()
    .describe(
      "A human-readable PR title (5-10 words) that summarizes the task"
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
  const systemPrompt = `You are a helpful assistant that generates git branch names and PR titles. Follow these rules exactly:

Branch names (without the 'cmux/' prefix):
- Format: <type>/<scope>/<short-imperative-slug>[-<issue>]
- Lowercase; use hyphens between words. Scopes and segments are separated by slashes.
- Keep total length reasonable (aim for 60 characters or fewer).
- <type> must be one of: feat, fix, chore, refactor, docs, test, perf, build, ci, revert, spike.
- <scope> is a stable area name (service, package, feature), 1–2 tokens (e.g., payments, auth, app-shell).
- <short-imperative-slug> uses 2–6 imperative words (avoid stopwords when possible).
- Optional [-<issue>] can include a tracker ID like -1234 or -PAY-123; use one format consistently.
- Do NOT include names, dates, environment names, or random IDs—the system will append a 'cmux/' prefix and a 5-character suffix later.

Special branches:
- Long-lived: main (default) or release/<x.y.z> (if relevant).
- Hotfixes: hotfix/<x.y.z>-<slug> (only for urgent fixes to a released version).
- Temporary spikes: spike/<scope>/<slug>. Avoid wip/; use draft PR state instead.

Branch titles (PR titles):
- Format: <type>(<scope>): <imperative summary> [<issue>]
- Use imperative, present tense verbs (e.g., "add", "update", "remove").
- Keep titles ≤ 72 characters, with no trailing period or emojis.
- Scope should match the branch scope when possible.
- Put issue identifiers at the end in parentheses when needed (e.g., (PAY-123) or (#8810)).

Examples:
- Task: Implement webhook signing for the payments integration (PAY-123)
  Branch: feat/payments/add-webhook-signing-PAY-123
  Title: feat(payments): add webhook signing (PAY-123)
- Task: Fix refresh token expiry issues in auth (#8810)
  Branch: fix/auth/renew-expired-refresh-tokens-8810
  Title: fix(auth): renew expired refresh tokens (#8810)
- Task: Simplify the layout grid in the app shell
  Branch: refactor/app-shell/simplify-layout-grid
  Title: refactor(app-shell): simplify layout grid
- Task: Document AWS key rotation runbook
  Branch: docs/infra/rotate-aws-keys
  Title: docs(infra): document AWS key rotation

Always output both the branch name and PR title following these rules.`;
  const userPrompt = `Task: ${taskDescription}`;

  const modelConfig = getModelAndProvider(apiKeys);

  if (!modelConfig) {
    serverLogger.warn(
      "[BranchNameGenerator] No API keys available, using fallback"
    );
    const words = taskDescription.split(/\s+/).slice(0, 5).join(" ");
    const summary = words || "feature update";
    return {
      branchName: buildDefaultBranchPath(summary),
      prTitle: summary,
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

    serverLogger.info(
      `[BranchNameGenerator] Generated via ${providerName}: branch="${object.branchName}", title="${object.prTitle}"`
    );
    return object;
  } catch (error) {
    serverLogger.error(
      `[BranchNameGenerator] ${providerName} API error:`,
      error
    );

    const words = taskDescription.split(/\s+/).slice(0, 5).join(" ");
    const summary = words || "feature update";
    return {
      branchName: buildDefaultBranchPath(summary),
      prTitle: summary,
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
  const branchName =
    result?.branchName ||
    buildDefaultBranchPath(
      taskDescription.split(/\s+/).slice(0, 5).join(" ") || "feature"
    );
  return `cmux/${branchName}`;
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
  return (
    prTitle ||
    taskDescription.split(/\s+/).slice(0, 5).join(" ") ||
    "feature update"
  );
}

/**
 * Generate multiple unique branch names given a PR title
 */
export function generateUniqueBranchNamesFromTitle(
  prTitle: string,
  count: number
): string[] {
  const basePath = buildDefaultBranchPath(prTitle);
  const baseName = `cmux/${basePath}`;
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
