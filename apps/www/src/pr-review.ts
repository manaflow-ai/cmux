import type { Instance } from "morphcloud";
import { MorphCloudClient } from "morphcloud";
import { Octokit } from "octokit";
import { readFile } from "node:fs/promises";
import { spawn } from "node:child_process";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import {
  codeReviewCallbackSchema,
  type CodeReviewCallbackPayload,
} from "@cmux/shared/codeReview/callback-schemas";

const DEFAULT_MORPH_SNAPSHOT_ID = "snapshot_vb7uqz8o";
const OPEN_VSCODE_PORT = 39378;
const REMOTE_WORKSPACE_DIR = "/root/workspace";
const REMOTE_LOG_FILE_PATH = "/root/pr-review-inject.log";
const WORKSPACE_LOG_RELATIVE_PATH = "pr-review-inject.log";
const WORKSPACE_LOG_ABSOLUTE_PATH = `${REMOTE_WORKSPACE_DIR}/${WORKSPACE_LOG_RELATIVE_PATH}`;

const moduleDir = dirname(fileURLToPath(import.meta.url));
const injectScriptSourcePath = resolve(
  moduleDir,
  "../scripts/pr-review/pr-review-inject.ts"
);
const injectScriptBundlePath = resolve(
  moduleDir,
  "../scripts/pr-review/pr-review-inject.bundle.js"
);

let cachedInjectScriptPromise: Promise<string> | null = null;

function getBunExecutable(): string {
  return process.env.BUN_RUNTIME ?? process.env.BUN_BIN ?? "bun";
}

async function buildInjectScript(): Promise<void> {
  const bunExecutable = getBunExecutable();
  console.log("[pr-review][debug] buildInjectScript resolving paths", {
    moduleDir,
    injectScriptSourcePath,
    injectScriptBundlePath,
  });
  const sourcePath = injectScriptSourcePath;
  const bundlePath = injectScriptBundlePath;

  console.log("[pr-review] Bundling inject script via bun build...");
  await new Promise<void>((resolve, reject) => {
    const child = spawn(
      bunExecutable,
      [
        "build",
        sourcePath,
        "--outfile",
        bundlePath,
        "--target",
        "bun",
        "--external",
        "@openai/codex-sdk",
        "--external",
        "@openai/codex",
        "--external",
        "zod",
      ],
      {
        stdio: "inherit",
      }
    );
    child.once("error", reject);
    child.once("exit", (code) => {
      if (code === 0) {
        resolve();
        return;
      }
      reject(
        new Error(
          `bun build exited with code ${code ?? "unknown"} when bundling inject script`
        )
      );
    });
  });
}

async function getInjectScriptSource(): Promise<string> {
  if (!cachedInjectScriptPromise) {
    cachedInjectScriptPromise = (async () => {
      console.log("[pr-review][debug] getInjectScriptSource triggering build");
      await buildInjectScript();
      console.log(
        `[pr-review][debug] Reading inject script bundle from ${injectScriptBundlePath}`
      );
      return readFile(injectScriptBundlePath, "utf8");
    })().catch((error) => {
      cachedInjectScriptPromise = null;
      throw error;
    });
  }
  return cachedInjectScriptPromise;
}

interface PrReviewCallbackConfig {
  url: string;
  token: string;
}

export interface PrReviewJobContext {
  jobId: string;
  teamId?: string;
  repoFullName: string;
  repoUrl: string;
  prNumber: number;
  prUrl: string;
  commitRef: string;
  callback?: PrReviewCallbackConfig;
  fileCallback?: PrReviewCallbackConfig;
  morphSnapshotId?: string;
}

interface ParsedPrUrl {
  owner: string;
  repo: string;
  number: number;
}

interface PrMetadata extends ParsedPrUrl {
  prUrl: string;
  headRefName: string;
  headRepoOwner: string;
  headRepoName: string;
  headSha: string;
  baseRefName: string;
}

type OctokitClient = InstanceType<typeof Octokit>;
type PullRequestGetResponse = Awaited<
  ReturnType<OctokitClient["rest"]["pulls"]["get"]>
>;
type GithubApiPullResponse = PullRequestGetResponse["data"];

function ensureMorphClient(): MorphCloudClient {
  const apiKey = process.env.MORPH_API_KEY;
  if (!apiKey) {
    throw new Error("MORPH_API_KEY environment variable is required");
  }
  return new MorphCloudClient({ apiKey });
}

async function sendCallback(
  callback: PrReviewCallbackConfig,
  payload: CodeReviewCallbackPayload
): Promise<void> {
  try {
    const validatedPayload = codeReviewCallbackSchema.parse(payload);
    const response = await fetch(callback.url, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Authorization: `Bearer ${callback.token}`,
      },
      body: JSON.stringify(validatedPayload),
    });
    if (!response.ok) {
      const text = await response.text();
      throw new Error(
        `Callback failed with status ${response.status}: ${text.slice(0, 2048)}`
      );
    }
  } catch (error) {
    const message =
      error instanceof Error ? error.message : String(error ?? "Unknown error");
    console.error(`[pr-review] Failed to send callback: ${message}`);
    throw error;
  }
}

function getGithubToken(): string | null {
  const token =
    process.env.GITHUB_TOKEN ??
    process.env.GH_TOKEN ??
    process.env.GITHUB_PERSONAL_ACCESS_TOKEN ??
    null;
  return token && token.length > 0 ? token : null;
}

function parsePrUrl(prUrl: string): ParsedPrUrl {
  let url: URL;
  try {
    url = new URL(prUrl);
  } catch (_error) {
    throw new Error(`Invalid PR URL: ${prUrl}`);
  }

  const pathParts = url.pathname.split("/").filter(Boolean);
  if (pathParts.length < 3 || pathParts[2] !== "pull") {
    throw new Error(
      `PR URL must be in the form https://github.com/<owner>/<repo>/pull/<number>, received: ${prUrl}`
    );
  }

  const [owner, repo, _pullSegment, prNumberPart] = pathParts;
  const prNumber = Number(prNumberPart);
  if (!Number.isInteger(prNumber)) {
    throw new Error(`Invalid PR number in URL: ${prUrl}`);
  }

  return { owner, repo, number: prNumber };
}

async function fetchPrMetadata(prUrl: string): Promise<PrMetadata> {
  const parsed = parsePrUrl(prUrl);
  const token = getGithubToken();
  const octokit = new Octokit(token ? { auth: token } : {});

  let data: GithubApiPullResponse;
  try {
    const response = await octokit.rest.pulls.get({
      owner: parsed.owner,
      repo: parsed.repo,
      pull_number: parsed.number,
    });
    data = response.data;
  } catch (error) {
    const message =
      error instanceof Error ? error.message : String(error ?? "unknown error");
    throw new Error(
      `Failed to fetch PR metadata via GitHub API: ${message}`.trim()
    );
  }

  const headRefName = data.head?.ref;
  if (typeof headRefName !== "string" || headRefName.length === 0) {
    throw new Error("PR metadata is missing head.ref.");
  }

  const headRepoName = data.head?.repo?.name;
  const headRepoOwner = data.head?.repo?.owner?.login;
  if (
    typeof headRepoName !== "string" ||
    headRepoName.length === 0 ||
    typeof headRepoOwner !== "string" ||
    headRepoOwner.length === 0
  ) {
    throw new Error("PR metadata is missing head repository information.");
  }

  const baseRefName = data.base?.ref;
  if (typeof baseRefName !== "string" || baseRefName.length === 0) {
    throw new Error("PR metadata is missing base.ref.");
  }

  const headSha = data.head?.sha;
  if (typeof headSha !== "string" || headSha.length === 0) {
    throw new Error("PR metadata is missing head.sha.");
  }

  const baseRepoName = data.base?.repo?.name;
  const baseRepoOwner = data.base?.repo?.owner?.login;

  return {
    owner:
      typeof baseRepoOwner === "string" && baseRepoOwner.length > 0
        ? baseRepoOwner
        : parsed.owner,
    repo:
      typeof baseRepoName === "string" && baseRepoName.length > 0
        ? baseRepoName
        : parsed.repo,
    number: parsed.number,
    prUrl,
    headRefName,
    headRepoName,
    headRepoOwner,
    headSha,
    baseRefName,
  };
}

function shellQuote(value: string): string {
  return `'${value.replace(/'/g, `'"'"'`)}'`;
}

function startTiming(label: string): () => void {
  const startTime = performance.now();
  let finished = false;
  return () => {
    if (finished) {
      return;
    }
    finished = true;
    const durationMs = performance.now() - startTime;
    const seconds = durationMs / 1000;
    console.log(`[timing] ${label} ${seconds.toFixed(2)}s`);
  };
}

async function execOrThrow(instance: Instance, command: string): Promise<void> {
  console.log("[pr-review][debug] Executing command on Morph instance", {
    commandPreview: command.slice(0, 160),
    instanceId: instance.id,
  });
  const result = await instance.exec(command);
  const exitCode = result.exit_code ?? 0;
  if (exitCode !== 0) {
    const stderr = result.stderr?.trim();
    const stdout = result.stdout?.trim();
    throw new Error(
      [
        `Command failed: ${command}`,
        stdout ? `stdout:\n${stdout}` : "",
        stderr ? `stderr:\n${stderr}` : "",
      ]
        .filter(Boolean)
        .join("\n\n")
    );
  }
  if (result.stdout && result.stdout.length > 0) {
    process.stdout.write(result.stdout);
    if (!result.stdout.endsWith("\n")) {
      process.stdout.write("\n");
    }
  }
  if (result.stderr && result.stderr.length > 0) {
    process.stderr.write(result.stderr);
    if (!result.stderr.endsWith("\n")) {
      process.stderr.write("\n");
    }
  }
}

function describeServices(instance: Instance): void {
  if (!instance.networking?.httpServices?.length) {
    console.log("No HTTP services exposed on the Morph instance yet.");
    return;
  }

  instance.networking.httpServices.forEach((service) => {
    console.log(
      `HTTP service ${service.name ?? `port-${service.port}`} -> ${service.url}`
    );
  });
}

function getOpenVscodeBaseUrl(
  instance: Instance,
  workspacePath: string
): URL | null {
  const services = instance.networking?.httpServices ?? [];
  const vscodeService = services.find(
    (service) =>
      service.port === OPEN_VSCODE_PORT ||
      service.name === `port-${OPEN_VSCODE_PORT}`
  );

  if (!vscodeService) {
    console.warn(
      `Warning: could not find exposed OpenVSCode service on port ${OPEN_VSCODE_PORT}.`
    );
    return null;
  }

  try {
    const vscodeUrl = new URL(vscodeService.url);
    vscodeUrl.searchParams.set("folder", workspacePath);
    return vscodeUrl;
  } catch (error) {
    const message =
      error instanceof Error ? error.message : String(error ?? "unknown error");
    console.warn(
      `Warning: unable to format OpenVSCode URL for port ${OPEN_VSCODE_PORT}: ${message}`
    );
    return null;
  }
}

function logOpenVscodeUrl(
  instance: Instance,
  workspacePath: string
): URL | null {
  const baseUrl = getOpenVscodeBaseUrl(instance, workspacePath);
  if (!baseUrl) {
    return null;
  }
  console.log(`OpenVSCode (${OPEN_VSCODE_PORT}): ${baseUrl.toString()}`);
  return baseUrl;
}

function logOpenVscodeFileUrl(
  instance: Instance,
  workspacePath: string,
  relativeFilePath: string
): void {
  const baseUrl = getOpenVscodeBaseUrl(instance, workspacePath);
  if (!baseUrl) {
    return;
  }

  const fileUrl = new URL(baseUrl.toString());
  fileUrl.searchParams.set("path", relativeFilePath);
  console.log(
    `OpenVSCode log file (${relativeFilePath}): ${fileUrl.toString()}`
  );
}

function buildMetadata(
  pr: PrMetadata,
  config: PrReviewJobContext
): Record<string, string> {
  return {
    purpose: "pr-review",
    prUrl: pr.prUrl,
    repo: `${pr.owner}/${pr.repo}`,
    head: `${pr.headRepoOwner}/${pr.headRepoName}#${pr.headRefName}`,
    jobId: config.jobId,
    ...(config.teamId ? { teamId: config.teamId } : {}),
    commitRef: config.commitRef,
  };
}

async function fetchPrMetadataTask(prUrl: string): Promise<PrMetadata> {
  console.log("Fetching PR metadata...");
  const finishFetchMetadata = startTiming("fetch PR metadata");
  try {
    return await fetchPrMetadata(prUrl);
  } finally {
    finishFetchMetadata();
  }
}

async function startMorphInstanceTask(
  client: MorphCloudClient,
  config: PrReviewJobContext
): Promise<Instance> {
  const snapshotId = config.morphSnapshotId ?? DEFAULT_MORPH_SNAPSHOT_ID;
  console.log(
    "[pr-review][debug] startMorphInstanceTask called",
    {
      snapshotId,
      jobId: config.jobId,
      repoFullName: config.repoFullName,
    }
  );
  console.log(`Starting Morph instance from snapshot ${snapshotId}...`);
  const finishStartInstance = startTiming("start Morph instance");
  try {
    return await client.instances.start({
      snapshotId,
      ttlSeconds: 60 * 30,
      ttlAction: "pause",
      metadata: {
        purpose: "pr-review",
        prUrl: config.prUrl,
        jobId: config.jobId,
        ...(config.teamId ? { teamId: config.teamId } : {}),
        repo: config.repoFullName,
      },
    });
  } catch (error) {
    const message =
      error instanceof Error ? error.message : String(error ?? "unknown error");
    console.error(`[pr-review] Failed to start Morph instance: ${message}`);
    throw error;
  } finally {
    finishStartInstance();
  }
}

export async function startAutomatedPrReview(
  config: PrReviewJobContext
): Promise<void> {
  console.log(
    `[pr-review] Preparing Morph review environment for ${config.prUrl}`
  );
  console.log("[pr-review][debug] startAutomatedPrReview config snapshot", {
    jobId: config.jobId,
    repoFullName: config.repoFullName,
    prUrl: config.prUrl,
    commitRef: config.commitRef,
    hasCallback: Boolean(config.callback),
    hasFileCallback: Boolean(config.fileCallback),
    morphSnapshotId: config.morphSnapshotId,
  });
  const morphClient = ensureMorphClient();
  let instance: Instance | null = null;

  try {
    console.log("[pr-review][debug] Starting parallel tasks", {
      jobId: config.jobId,
    });
    const startInstancePromise = startMorphInstanceTask(
      morphClient,
      config
    ).then((startedInstance) => {
      instance = startedInstance;
      return startedInstance;
    });
    const prMetadataPromise = fetchPrMetadataTask(config.prUrl);

    const [prMetadata, startedInstance] = await Promise.all([
      prMetadataPromise,
      startInstancePromise,
    ]);
    instance = startedInstance;

    const normalizedCommitRef =
      config.commitRef === "unknown" && prMetadata.headSha
        ? prMetadata.headSha
        : config.commitRef;

    const metadataConfig =
      normalizedCommitRef === config.commitRef
        ? config
        : { ...config, commitRef: normalizedCommitRef };

    console.log(
      `[pr-review] Targeting ${prMetadata.headRepoOwner}/${prMetadata.headRepoName}@${prMetadata.headRefName}`
    );
    console.log("[pr-review][debug] Commit context", {
      originalCommitRef: config.commitRef,
      normalizedCommitRef,
      headSha: prMetadata.headSha,
    });

    try {
      await startedInstance.setMetadata(
        buildMetadata(prMetadata, metadataConfig)
      );
    } catch (metadataError) {
      const message =
        metadataError instanceof Error
          ? metadataError.message
          : String(metadataError ?? "unknown error");
      console.warn(
        `[pr-review] Warning: failed to set metadata for instance ${startedInstance.id}: ${message}`
      );
    }

    console.log("[pr-review] Waiting for Morph instance to be ready...");
    const finishWaitReady = startTiming("wait for Morph instance ready");
    try {
      await startedInstance.waitUntilReady();
    } finally {
      finishWaitReady();
    }
    console.log(`[pr-review] Instance ${startedInstance.id} is ready.`);

    describeServices(startedInstance);
    logOpenVscodeUrl(startedInstance, REMOTE_WORKSPACE_DIR);

    const openAiApiKey = process.env.OPENAI_API_KEY;
    if (!openAiApiKey || openAiApiKey.length === 0) {
      throw new Error(
        "OPENAI_API_KEY environment variable is required to run PR review."
      );
    }

    const remoteScriptPath = "/root/pr-review-inject.ts";
    const injectScriptSource = await getInjectScriptSource();
    const baseRepoUrl = `https://github.com/${prMetadata.owner}/${prMetadata.repo}.git`;
    const headRepoUrl = `https://github.com/${prMetadata.headRepoOwner}/${prMetadata.headRepoName}.git`;

    const envPairs: Array<[string, string]> = [
      ["WORKSPACE_DIR", REMOTE_WORKSPACE_DIR],
      ["PR_URL", prMetadata.prUrl],
      ["GIT_REPO_URL", headRepoUrl],
      ["GIT_BRANCH", prMetadata.headRefName],
      ["BASE_REPO_URL", baseRepoUrl],
      ["BASE_REF_NAME", prMetadata.baseRefName],
      ["OPENAI_API_KEY", openAiApiKey],
      ["LOG_FILE_PATH", REMOTE_LOG_FILE_PATH],
      ["LOG_SYMLINK_PATH", WORKSPACE_LOG_ABSOLUTE_PATH],
      ["JOB_ID", config.jobId],
      ["SANDBOX_INSTANCE_ID", startedInstance.id],
      ["REPO_FULL_NAME", config.repoFullName],
      ["COMMIT_REF", normalizedCommitRef],
    ];

    if (config.callback) {
      envPairs.push(["CALLBACK_URL", config.callback.url]);
      envPairs.push(["CALLBACK_TOKEN", config.callback.token]);
    }
    if (config.fileCallback) {
      envPairs.push(["FILE_CALLBACK_URL", config.fileCallback.url]);
      envPairs.push(["FILE_CALLBACK_TOKEN", config.fileCallback.token]);
    }
    if (config.teamId) {
      envPairs.push(["TEAM_ID", config.teamId]);
    }

    const envAssignments = envPairs
      .map(([key, value]) => `${key}=${shellQuote(value)}`)
      .join(" ");
    const injectCommand =
      [
        `cat <<'EOF_PR_REVIEW_INJECT' > ${shellQuote(remoteScriptPath)}`,
        injectScriptSource,
        "EOF_PR_REVIEW_INJECT",
        `chmod +x ${shellQuote(remoteScriptPath)}`,
        `rm -f ${shellQuote(REMOTE_LOG_FILE_PATH)}`,
        `nohup env ${envAssignments} bun ${shellQuote(
          remoteScriptPath
        )} > ${shellQuote(REMOTE_LOG_FILE_PATH)} 2>&1 &`,
      ].join("\n") + "\n";

    const finishPrepareRepo = startTiming("dispatch review script");
    try {
      await execOrThrow(startedInstance, injectCommand);
    } finally {
      finishPrepareRepo();
    }

    console.log(
      `[pr-review] Repository preparation is running in the background. Remote log: ${REMOTE_LOG_FILE_PATH}`
    );
    console.log(
      `[pr-review] Symlinked workspace log (once created): ${WORKSPACE_LOG_ABSOLUTE_PATH}`
    );
    logOpenVscodeFileUrl(
      startedInstance,
      REMOTE_WORKSPACE_DIR,
      WORKSPACE_LOG_RELATIVE_PATH
    );
    console.log(
      `[pr-review] Morph instance ${startedInstance.id} provisioned for PR ${prMetadata.prUrl}`
    );
  } catch (error) {
    const message =
      error instanceof Error ? error.message : String(error ?? "Unknown error");
    console.error(`[pr-review] Failure during setup: ${message}`);

    console.log("[pr-review][debug] Failure context", {
      jobId: config.jobId,
      instanceId: instance?.id ?? null,
      errorMessage: message,
    });

    if (config.callback && instance) {
      try {
        await sendCallback(config.callback, {
          status: "error",
          jobId: config.jobId,
          sandboxInstanceId: instance.id,
          errorCode: "pr_review_setup_failed",
          errorDetail: message,
        });
      } catch (callbackError) {
        const callbackMessage =
          callbackError instanceof Error
            ? callbackError.message
            : String(callbackError ?? "Unknown callback error");
        console.error(
          `[pr-review] Callback dispatch failed: ${callbackMessage}`
        );
      }
    } else if (config.callback && !instance) {
      console.warn(
        "[pr-review][debug] Skipping failure callback because Morph instance was never provisioned",
        { jobId: config.jobId }
      );
    }

    if (instance) {
      try {
        await instance.pause();
      } catch (pauseError) {
        const pauseMessage =
          pauseError instanceof Error
            ? pauseError.message
            : String(pauseError ?? "Unknown pause error");
        console.warn(
          `[pr-review] Warning: failed to pause instance ${instance.id}: ${pauseMessage}`
        );
      }
    }
    throw error;
  }
}
