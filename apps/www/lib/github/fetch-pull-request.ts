import { unstable_cache } from "next/cache";

import { GithubApiError } from "./errors";
import { createGitHubClient } from "./octokit";
import {
  generateGitHubInstallationToken,
  getInstallationForRepo,
} from "../utils/github-app-token";

type RequestErrorShape = {
  status?: number;
  message?: string;
  documentation_url?: string;
};

type OctokitInstance = ReturnType<typeof createGitHubClient>;

type PullRequestResponse = Awaited<
  ReturnType<OctokitInstance["rest"]["pulls"]["get"]>
>;

type PullRequestFilesResponse = Awaited<
  ReturnType<OctokitInstance["rest"]["pulls"]["listFiles"]>
>;

type CompareCommitsResponse = Awaited<
  ReturnType<OctokitInstance["rest"]["repos"]["compareCommitsWithBasehead"]>
>;

export type GithubPullRequest = PullRequestResponse["data"];

export type GithubPullRequestFile =
  PullRequestFilesResponse["data"][number];

export type GithubComparison = CompareCommitsResponse["data"];

const DEFAULT_CACHE_WINDOW_MS = 2_000;
const DEFAULT_COMPARISON_CACHE_WINDOW_MS = 2_000;
const FULL_SHA_REGEX = /^[0-9a-f]{40}$/i;

type GithubRequestOptionsInput = {
  authToken?: string | null;
  /**
   * Optional ref (branch name or commit SHA) used to scope caching.
   * Prefer providing a commit SHA when available for more stable caching.
   */
  ref?: string | null;
  /**
   * Override the rolling cache window in milliseconds.
   * Use 0 or a negative value to disable caching.
   */
  cacheWindowMs?: number | null;
  /**
   * Explicitly disable caching for this request.
   */
  disableCache?: boolean | null;
};

type NormalizedGithubRequestOptions = {
  authToken: string | null;
  ref: string | null;
  cacheWindowMs: number;
  disableCache: boolean;
};

type FetchPullRequestOptions = GithubRequestOptionsInput;

type FetchPullRequestFilesOptions = GithubRequestOptionsInput;

function normalizeGithubRequestOptions(
  options?: GithubRequestOptionsInput,
): NormalizedGithubRequestOptions {
  const normalized: NormalizedGithubRequestOptions = {
    authToken: null,
    ref: null,
    cacheWindowMs: DEFAULT_CACHE_WINDOW_MS,
    disableCache: false,
  };

  if (!options) {
    return normalized;
  }

  if (typeof options.authToken === "string") {
    const trimmed = options.authToken.trim();
    if (trimmed.length > 0) {
      normalized.authToken = trimmed;
    }
  }

  if (typeof options.ref === "string") {
    const trimmedRef = options.ref.trim();
    if (trimmedRef.length > 0) {
      normalized.ref = trimmedRef;
    }
  }

  if (
    typeof options.cacheWindowMs === "number" &&
    Number.isFinite(options.cacheWindowMs)
  ) {
    const coerced = Math.floor(options.cacheWindowMs);
    normalized.cacheWindowMs = coerced > 0 ? coerced : 0;
  }

  if (options.disableCache === true) {
    normalized.disableCache = true;
  }

  return normalized;
}

function serializeGithubRequestOptions(
  options: NormalizedGithubRequestOptions,
): string {
  return JSON.stringify(options);
}

function deserializeGithubRequestOptions(
  serialized: string,
): NormalizedGithubRequestOptions {
  try {
    const parsed = JSON.parse(serialized) as GithubRequestOptionsInput;
    return normalizeGithubRequestOptions(parsed);
  } catch {
    return normalizeGithubRequestOptions();
  }
}

function getTimeBucket(windowMs: number, now: number): string | null {
  if (!Number.isFinite(windowMs) || windowMs <= 0) {
    return null;
  }
  return Math.floor(now / windowMs).toString();
}

function isFullGitSha(ref: string): boolean {
  return FULL_SHA_REGEX.test(ref);
}

function computeCacheBucket(
  options: NormalizedGithubRequestOptions,
  now: number,
): string | null {
  const bucket = getTimeBucket(options.cacheWindowMs, now);

  if (options.ref) {
    if (isFullGitSha(options.ref)) {
      return `sha:${options.ref}`;
    }
    if (bucket !== null) {
      return `ref:${options.ref}:bucket:${bucket}`;
    }
    return null;
  }

  if (bucket === null) {
    return null;
  }

  return `time:${bucket}`;
}

function computeComparisonCacheBucket(
  baseRef: string,
  headRef: string,
  now: number,
): string | null {
  const bothAreShas =
    isFullGitSha(baseRef) && isFullGitSha(headRef);

  if (bothAreShas) {
    return `comparison:${baseRef}:${headRef}`;
  }

  const bucket = getTimeBucket(DEFAULT_COMPARISON_CACHE_WINDOW_MS, now);
  if (bucket === null) {
    return null;
  }

  return `comparison:time:${bucket}`;
}

function toGithubApiError(error: unknown): GithubApiError {
  if (error instanceof GithubApiError) {
    return error;
  }

  if (isRequestErrorShape(error)) {
    const status = typeof error.status === "number" ? error.status : 500;
    const message =
      typeof error.message === "string"
        ? error.message
        : "Unexpected GitHub API error";
    const documentationUrl =
      typeof error.documentation_url === "string"
        ? error.documentation_url
        : undefined;

    return new GithubApiError(message, { status, documentationUrl });
  }

  return new GithubApiError("Unexpected GitHub API error", {
    status: 500,
  });
}

function isRequestErrorShape(error: unknown): error is RequestErrorShape {
  if (typeof error !== "object" || error === null) {
    return false;
  }

  const maybeShape = error as Record<string, unknown>;
  return (
    "status" in maybeShape ||
    "message" in maybeShape ||
    "documentation_url" in maybeShape
  );
}

function buildAuthCandidates(
  token: string | null | undefined,
): (string | undefined)[] {
  const candidates: (string | undefined)[] = [];
  if (typeof token === "string" && token.trim().length > 0) {
    candidates.push(token);
  }
  candidates.push(undefined);
  return candidates.filter(
    (candidate, index) =>
      candidates.findIndex((value) => value === candidate) === index,
  );
}

function shouldRetryWithAlternateAuth(error: unknown): boolean {
  if (!isRequestErrorShape(error)) {
    return false;
  }
  return [401, 403, 404].includes(error.status ?? 0);
}

async function performFetchPullRequest(
  owner: string,
  repo: string,
  pullNumber: number,
  options: NormalizedGithubRequestOptions,
): Promise<GithubPullRequest> {
  const authCandidates = buildAuthCandidates(options.authToken);
  let lastError: unknown;

  for (const candidate of authCandidates) {
    try {
      const octokit = createGitHubClient(candidate);
      const response = await octokit.rest.pulls.get({
        owner,
        repo,
        pull_number: pullNumber,
      });
      return response.data;
    } catch (error) {
      lastError = error;
      if (shouldRetryWithAlternateAuth(error)) {
        continue;
      }
      throw toGithubApiError(error);
    }
  }

  if (isRequestErrorShape(lastError) && lastError.status === 404) {
    console.log(
      `[fetchPullRequest] Got 404, trying with GitHub App token for ${owner}/${repo}`,
    );

    const installationId = await getInstallationForRepo(`${owner}/${repo}`);
    if (installationId) {
      const appToken = await generateGitHubInstallationToken({
        installationId,
        permissions: {
          contents: "read",
          metadata: "read",
          pull_requests: "read",
        },
      });

      try {
        const octokit = createGitHubClient(appToken);
        const response = await octokit.rest.pulls.get({
          owner,
          repo,
          pull_number: pullNumber,
        });
        return response.data;
      } catch (appError) {
        throw toGithubApiError(appError);
      }
    }
  }

  if (lastError) {
    throw toGithubApiError(lastError);
  }

  throw new GithubApiError("Unable to fetch pull request", {
    status: 500,
  });
}

const cachedFetchPullRequest = unstable_cache(
  async (
    owner: string,
    repo: string,
    pullNumber: number,
    serializedOptions: string,
    cacheBucket: string,
  ): Promise<GithubPullRequest> => {
    void cacheBucket;
    const normalizedOptions =
      deserializeGithubRequestOptions(serializedOptions);
    try {
      return await performFetchPullRequest(
        owner,
        repo,
        pullNumber,
        normalizedOptions,
      );
    } catch (error) {
      throw toGithubApiError(error);
    }
  },
  ["github", "fetchPullRequest"],
);

export async function fetchPullRequest(
  owner: string,
  repo: string,
  pullNumber: number,
  options: FetchPullRequestOptions = {},
): Promise<GithubPullRequest> {
  const normalizedOptions = normalizeGithubRequestOptions(options);

  if (normalizedOptions.disableCache) {
    return await performFetchPullRequest(
      owner,
      repo,
      pullNumber,
      normalizedOptions,
    );
  }

  const now = Date.now();
  const cacheBucket = computeCacheBucket(normalizedOptions, now);

  if (cacheBucket === null) {
    return await performFetchPullRequest(
      owner,
      repo,
      pullNumber,
      normalizedOptions,
    );
  }

  const serializedOptions =
    serializeGithubRequestOptions(normalizedOptions);

  try {
    return await cachedFetchPullRequest(
      owner,
      repo,
      pullNumber,
      serializedOptions,
      cacheBucket,
    );
  } catch (error) {
    throw toGithubApiError(error);
  }
}

async function performFetchPullRequestFiles(
  owner: string,
  repo: string,
  pullNumber: number,
  options: NormalizedGithubRequestOptions,
): Promise<GithubPullRequestFile[]> {
  const authCandidates = buildAuthCandidates(options.authToken);
  let lastError: unknown;

  for (const candidate of authCandidates) {
    try {
      const octokit = createGitHubClient(candidate);
      const files = await octokit.paginate(octokit.rest.pulls.listFiles, {
        owner,
        repo,
        pull_number: pullNumber,
        per_page: 100,
      });
      return files;
    } catch (error) {
      lastError = error;
      if (shouldRetryWithAlternateAuth(error)) {
        continue;
      }
      throw toGithubApiError(error);
    }
  }

  if (isRequestErrorShape(lastError) && lastError.status === 404) {
    console.log(
      `[fetchPullRequestFiles] Got 404, trying with GitHub App token for ${owner}/${repo}`,
    );

    const installationId = await getInstallationForRepo(`${owner}/${repo}`);
    if (installationId) {
      const appToken = await generateGitHubInstallationToken({
        installationId,
        permissions: {
          contents: "read",
          metadata: "read",
          pull_requests: "read",
        },
      });

      try {
        const octokit = createGitHubClient(appToken);
        const files = await octokit.paginate(octokit.rest.pulls.listFiles, {
          owner,
          repo,
          pull_number: pullNumber,
          per_page: 100,
        });
        return files;
      } catch (appError) {
        throw toGithubApiError(appError);
      }
    }
  }

  if (lastError) {
    throw toGithubApiError(lastError);
  }

  throw new GithubApiError("Unable to fetch pull request files", {
    status: 500,
  });
}

const cachedFetchPullRequestFiles = unstable_cache(
  async (
    owner: string,
    repo: string,
    pullNumber: number,
    serializedOptions: string,
    cacheBucket: string,
  ): Promise<GithubPullRequestFile[]> => {
    void cacheBucket;
    const normalizedOptions =
      deserializeGithubRequestOptions(serializedOptions);
    try {
      return await performFetchPullRequestFiles(
        owner,
        repo,
        pullNumber,
        normalizedOptions,
      );
    } catch (error) {
      throw toGithubApiError(error);
    }
  },
  ["github", "fetchPullRequestFiles"],
);

export async function fetchPullRequestFiles(
  owner: string,
  repo: string,
  pullNumber: number,
  options: FetchPullRequestFilesOptions = {},
): Promise<GithubPullRequestFile[]> {
  const normalizedOptions = normalizeGithubRequestOptions(options);

  if (normalizedOptions.disableCache) {
    return await performFetchPullRequestFiles(
      owner,
      repo,
      pullNumber,
      normalizedOptions,
    );
  }

  const now = Date.now();
  const cacheBucket = computeCacheBucket(normalizedOptions, now);

  if (cacheBucket === null) {
    return await performFetchPullRequestFiles(
      owner,
      repo,
      pullNumber,
      normalizedOptions,
    );
  }

  const serializedOptions =
    serializeGithubRequestOptions(normalizedOptions);

  try {
    return await cachedFetchPullRequestFiles(
      owner,
      repo,
      pullNumber,
      serializedOptions,
      cacheBucket,
    );
  } catch (error) {
    throw toGithubApiError(error);
  }
}

type GithubComparisonFile = NonNullable<CompareCommitsResponse["data"]["files"]>[number];

export type GithubFileChange = {
  filename: GithubPullRequestFile["filename"];
  status: GithubPullRequestFile["status"];
  additions: GithubPullRequestFile["additions"];
  deletions: GithubPullRequestFile["deletions"];
  changes: GithubPullRequestFile["changes"];
  previous_filename?: GithubPullRequestFile["previous_filename"];
  patch?: GithubPullRequestFile["patch"];
};

export function toGithubFileChange(
  file: GithubPullRequestFile | GithubComparisonFile,
): GithubFileChange {
  return {
    filename: file.filename,
    status: file.status,
    additions: file.additions,
    deletions: file.deletions,
    changes: file.changes,
    previous_filename: file.previous_filename,
    patch: file.patch,
  };
}

async function performFetchComparison(
  owner: string,
  repo: string,
  baseRef: string,
  headRef: string,
): Promise<GithubComparison> {
  const octokit = createGitHubClient();
  const response = await octokit.rest.repos.compareCommitsWithBasehead({
    owner,
    repo,
    basehead: `${baseRef}...${headRef}`,
    per_page: 100,
  });
  return response.data;
}

const cachedFetchComparison = unstable_cache(
  async (
    owner: string,
    repo: string,
    baseRef: string,
    headRef: string,
    cacheBucket: string,
  ): Promise<GithubComparison> => {
    void cacheBucket;
    try {
      return await performFetchComparison(owner, repo, baseRef, headRef);
    } catch (error) {
      throw toGithubApiError(error);
    }
  },
  ["github", "fetchComparison"],
);

export async function fetchComparison(
  owner: string,
  repo: string,
  baseRef: string,
  headRef: string,
): Promise<GithubComparison> {
  const now = Date.now();
  const cacheBucket = computeComparisonCacheBucket(baseRef, headRef, now);

  if (cacheBucket === null) {
    try {
      return await performFetchComparison(owner, repo, baseRef, headRef);
    } catch (error) {
      throw toGithubApiError(error);
    }
  }

  try {
    return await cachedFetchComparison(
      owner,
      repo,
      baseRef,
      headRef,
      cacheBucket,
    );
  } catch (error) {
    throw toGithubApiError(error);
  }
}
