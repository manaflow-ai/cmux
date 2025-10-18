#!/usr/bin/env bun

import { execFile } from "node:child_process";
import { randomUUID } from "node:crypto";
import process from "node:process";
import readline from "node:readline/promises";
import { promisify } from "node:util";
import {
  startAutomatedPrReview,
  type PrReviewJobContext,
} from "../src/pr-review";

const DEFAULT_PR_URL = "https://github.com/manaflow-ai/cmux/pull/653";
const execFileAsync = promisify(execFile);

interface ParsedPrUrl {
  owner: string;
  repo: string;
  number: number;
}

function parsePrUrl(prUrl: string): ParsedPrUrl {
  let url: URL;
  try {
    url = new URL(prUrl);
  } catch (_error) {
    throw new Error(`Invalid PR URL: ${prUrl}`);
  }

  const parts = url.pathname.split("/").filter(Boolean);
  if (parts.length < 4 || parts[2] !== "pull") {
    throw new Error(
      `PR URL must be in the form https://github.com/<owner>/<repo>/pull/<number>, received: ${prUrl}`
    );
  }

  const [owner, repo, _pull, numberRaw] = parts;
  const number = Number(numberRaw);
  if (!Number.isInteger(number)) {
    throw new Error(`Invalid pull request number in URL: ${prUrl}`);
  }

  return { owner, repo, number };
}

async function resolveCommitRef(
  repoFullName: string,
  prNumber: number
): Promise<string> {
  const prIdentifier = `${repoFullName}#${prNumber}`;
  try {
    const { stdout } = await execFileAsync("gh", [
      "pr",
      "view",
      String(prNumber),
      "--repo",
      repoFullName,
      "--json",
      "headRefOid",
      "--jq",
      ".headRefOid",
    ]);
    const commitRef = stdout.trim();
    if (!commitRef) {
      throw new Error(
        `GitHub CLI returned an empty commit ref for ${prIdentifier}`
      );
    }
    return commitRef;
  } catch (error) {
    const baseMessage = `Failed to fetch head commit for ${prIdentifier} via gh`;
    if (error instanceof Error) {
      throw new Error(`${baseMessage}: ${error.message}`, { cause: error });
    }
    throw new Error(baseMessage);
  }
}

async function main(): Promise<void> {
  const prUrlInput = process.argv[2] ?? DEFAULT_PR_URL;
  const prUrl = prUrlInput.trim();
  if (prUrl.length === 0) {
    throw new Error("PR URL argument cannot be empty");
  }

  const parsed = parsePrUrl(prUrl);
  const repoFullName = `${parsed.owner}/${parsed.repo}`;
  const repoUrl = `https://github.com/${repoFullName}.git`;
  const jobId = randomUUID();
  const sandboxLabel = randomUUID();

  console.log(`[cli] Starting PR review for ${repoFullName}#${parsed.number}`);
  const commitRef = await resolveCommitRef(repoFullName, parsed.number);

  const config: PrReviewJobContext = {
    jobId,
    teamId: "780c4397-90dd-47f1-b336-b8c376039db5",
    repoFullName,
    repoUrl,
    prNumber: parsed.number,
    prUrl,
    commitRef,
    morphSnapshotId: "snapshot_vb7uqz8o",
  };

  try {
    await startAutomatedPrReview(config);
    console.log(
      `[cli] Review launched (jobId=${jobId}, sandboxHint=${sandboxLabel}).`
    );
    console.log("[cli] Press Enter to exit.");
    const rl = readline.createInterface({
      input: process.stdin,
      output: process.stdout,
    });
    await rl.question("");
    rl.close();
  } catch (error) {
    const message =
      error instanceof Error ? error.message : String(error ?? "unknown error");
    console.error(`[cli] Review setup failed: ${message}`);
    throw error;
  }
}

await main().catch((error) => {
  console.error(
    error instanceof Error ? (error.stack ?? error.message) : error
  );
  process.exit(1);
});
