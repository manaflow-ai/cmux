#!/usr/bin/env bun

import process from "node:process";

import { Octokit } from "octokit";

import { __TEST_INTERNAL_ONLY_GET_STACK_TOKENS } from "@/lib/test-utils/__TEST_INTERNAL_ONLY_GET_STACK_TOKENS";
import {
  getConvexHttpActionBaseUrl,
  startCodeReviewJob,
} from "@/lib/services/code-review/start-code-review";

const DEFAULT_PR_URL = "https://github.com/manaflow-ai/cmux/pull/661";
type CliOptions = {
  prUrl: string;
  commitRef?: string;
  teamSlugOrId?: string;
  force?: boolean;
};

type ParsedPrUrl = {
  owner: string;
  repo: string;
  number: number;
};

function parseArgs(): CliOptions {
  const args = process.argv.slice(2);
  let prUrl = DEFAULT_PR_URL;
  let commitRef: string | undefined;
  let teamSlugOrId: string | undefined;
  let force: boolean | undefined;

  for (let index = 0; index < args.length; index += 1) {
    const arg = args[index];
    if (arg === "--pr" || arg === "--pr-url") {
      prUrl = args[index + 1] ?? prUrl;
      index += 1;
      continue;
    }
    if (arg === "--team") {
      teamSlugOrId = args[index + 1];
      index += 1;
      continue;
    }
    if (arg === "--commit" || arg === "--commit-ref") {
      commitRef = args[index + 1];
      index += 1;
      continue;
    }
    if (arg === "--force") {
      force = true;
      continue;
    }
    if (arg === "--no-force") {
      force = false;
      continue;
    }
    if (!arg.startsWith("--")) {
      prUrl = arg;
      continue;
    }
    console.warn(`[cli] Unrecognized argument ignored: ${arg}`);
  }

  return { prUrl, commitRef, teamSlugOrId, force };
}

function parsePrUrl(prUrl: string): ParsedPrUrl {
  let parsedUrl: URL;
  try {
    parsedUrl = new URL(prUrl);
  } catch (_error) {
    throw new Error(`Invalid PR URL: ${prUrl}`);
  }

  const parts = parsedUrl.pathname.split("/").filter(Boolean);
  if (parts.length < 4 || parts[2] !== "pull") {
    throw new Error(
      `PR URL must be in the form https://github.com/<owner>/<repo>/pull/<number>, received: ${prUrl}`
    );
  }

  const [owner, repo, _pullSegment, numberRaw] = parts;
  const number = Number(numberRaw);
  if (!Number.isInteger(number)) {
    throw new Error(`Invalid PR number in URL: ${prUrl}`);
  }

  return { owner, repo, number };
}

function getGithubToken(): string | null {
  const token =
    process.env.GITHUB_TOKEN ??
    process.env.GH_TOKEN ??
    process.env.GITHUB_PERSONAL_ACCESS_TOKEN ??
    null;
  return token && token.length > 0 ? token : null;
}

async function fetchHeadCommitSha(pr: ParsedPrUrl): Promise<string | undefined> {
  const token = getGithubToken();
  const octokit = new Octokit(token ? { auth: token } : {});
  try {
    const { data } = await octokit.rest.pulls.get({
      owner: pr.owner,
      repo: pr.repo,
      pull_number: pr.number,
    });
    const sha = data.head?.sha;
    if (typeof sha === "string" && sha.length > 0) {
      return sha;
    }
    console.warn("[cli] Pull request response missing head.sha; falling back to unknown", {
      owner: pr.owner,
      repo: pr.repo,
      number: pr.number,
    });
  } catch (error) {
    console.warn("[cli] Failed to fetch PR metadata for commit ref", {
      owner: pr.owner,
      repo: pr.repo,
      number: pr.number,
      error,
    });
  }
  return undefined;
}

async function main(): Promise<void> {
  const cliOptions = parseArgs();
  const prUrl = cliOptions.prUrl.trim();
  if (prUrl.length === 0) {
    throw new Error("PR URL cannot be empty");
  }

  const pr = parsePrUrl(prUrl);
  const teamSlugOrId = cliOptions.teamSlugOrId;
  const inferredTeam = teamSlugOrId ?? pr.owner;

  const commitRef =
    cliOptions.commitRef ??
    (await fetchHeadCommitSha(pr));

  console.info("[cli] Starting production-style code review", {
    prUrl,
    teamParam: teamSlugOrId ?? "(not provided)",
    inferredTeam,
    commitRef: commitRef ?? "(unknown)",
    force: cliOptions.force ?? false,
  });

  const tokens = await __TEST_INTERNAL_ONLY_GET_STACK_TOKENS();
  const callbackBaseUrl = getConvexHttpActionBaseUrl();
  if (!callbackBaseUrl) {
    throw new Error("NEXT_PUBLIC_CONVEX_URL is not configured");
  }

  if (!commitRef) {
    console.warn("[cli] Proceeding without commit ref; Convex job will infer or store 'unknown'.");
  }

  const { job, deduplicated, backgroundTask } = await startCodeReviewJob({
    accessToken: tokens.accessToken,
    callbackBaseUrl,
    payload: {
      teamSlugOrId,
      githubLink: prUrl,
      prNumber: pr.number,
      commitRef,
      force: cliOptions.force,
    },
  });

  console.info("[cli] Code review job queued", {
    jobId: job.jobId,
    state: job.state,
    deduplicated,
    repoFullName: job.repoFullName,
    prNumber: job.prNumber,
  });

  if (backgroundTask) {
    console.info("[cli] Awaiting background task to finish execution...");
    try {
      await backgroundTask;
      console.info("[cli] Background task signalled completion");
    } catch (error) {
      const message =
        error instanceof Error ? error.message : String(error ?? "unknown error");
      console.error("[cli] Background task failed", { message });
      throw error;
    }
  } else {
    console.info("[cli] Job reused existing execution; nothing else to await.");
  }
}

await main().catch((error) => {
  console.error(
    error instanceof Error ? error.stack ?? error.message : String(error)
  );
  process.exit(1);
});
