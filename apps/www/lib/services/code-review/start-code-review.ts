import { randomBytes, createHash } from "node:crypto";
import { api } from "@cmux/convex/api";
import type { Id } from "@cmux/convex/dataModel";

import { getConvex } from "@/lib/utils/get-convex";
import { verifyTeamAccess } from "@/lib/utils/team-verification";
import { env } from "@/lib/utils/www-env";
import {
  startAutomatedPrReview,
  type PrReviewJobContext,
} from "@/src/pr-review";
import type { ComparisonJobDetails } from "./comparison";
import { PR_REVIEW_STRATEGY } from "@/pr-review.config";
import { runHeatmapReview } from "./run-heatmap-review";
import { loadOptionsFromEnv } from "@/scripts/pr-review/core/options";
import type { PrReviewStrategyId } from "@/scripts/pr-review/core/options";

type ComparisonJobPayload = Pick<ComparisonJobDetails, "slug" | "base" | "head">;

type StartCodeReviewPayload = {
  teamSlugOrId?: string;
  githubLink: string;
  prNumber?: number;
  commitRef?: string;
  headCommitRef?: string;
  baseCommitRef?: string;
  force?: boolean;
  comparison?: ComparisonJobPayload;
};

type StartCodeReviewOptions = {
  accessToken: string;
  githubAccessToken: string | null;
  callbackBaseUrl: string;
  payload: StartCodeReviewPayload;
  request?: Request;
};

type StartCodeReviewResult = {
  job: {
    jobId: string;
    teamId: string | null;
    repoFullName: string;
    repoUrl: string;
    prNumber: number | null;
    commitRef: string;
    headCommitRef: string;
    baseCommitRef: string | null;
    requestedByUserId: string;
    state: string;
    createdAt: number;
    updatedAt: number;
    startedAt: number | null;
    completedAt: number | null;
    sandboxInstanceId: string | null;
    errorCode: string | null;
    errorDetail: string | null;
    codeReviewOutput: Record<string, unknown> | null;
    jobType: "pull_request" | "comparison";
    comparisonSlug: string | null;
    comparisonBaseOwner: string | null;
    comparisonBaseRef: string | null;
    comparisonHeadOwner: string | null;
    comparisonHeadRef: string | null;
    sharingScope: "team" | "shared";
  };
  deduplicated: boolean;
  backgroundTask: Promise<void> | null;
};

function hashCallbackToken(token: string): string {
  return createHash("sha256").update(token).digest("hex");
}

function resolveStrategy(): PrReviewStrategyId {
  const override = process.env.CMUX_PR_REVIEW_STRATEGY;
  if (typeof override === "string" && override.trim().length > 0) {
    const options = loadOptionsFromEnv(process.env);
    return options.strategy;
  }
  return PR_REVIEW_STRATEGY;
}

export function getConvexHttpActionBaseUrl(): string | null {
  const url = env.NEXT_PUBLIC_CONVEX_URL;
  if (!url) {
    return null;
  }
  return url.replace(".convex.cloud", ".convex.site").replace(/\/$/, "");
}

export async function startCodeReviewJob({
  accessToken,
  githubAccessToken,
  callbackBaseUrl,
  payload,
  request,
}: StartCodeReviewOptions): Promise<StartCodeReviewResult> {
  const strategy = resolveStrategy();
  const jobType: "pull_request" | "comparison" = payload.comparison
    ? "comparison"
    : "pull_request";

  if (jobType === "pull_request" && typeof payload.prNumber !== "number") {
    throw new Error("prNumber is required for pull request code review jobs");
  }
  if (jobType === "comparison" && !payload.comparison) {
    throw new Error("comparison metadata is required for comparison jobs");
  }

  if (payload.teamSlugOrId) {
    try {
      await verifyTeamAccess({
        accessToken,
        req: request,
        teamSlugOrId: payload.teamSlugOrId,
      });
    } catch (error) {
      console.warn("[code-review] Failed to verify team access", {
        teamSlugOrId: payload.teamSlugOrId,
        error,
      });
      throw error;
    }
  } else {
    const inferredSlug = payload.githubLink.split("/")[3] ?? "unknown";
    console.info("[code-review] No team slug provided; using repo owner from URL", {
      inferredSlug,
      githubLink: payload.githubLink,
    });
  }

  const rawHeadCommitRef = payload.headCommitRef ?? payload.commitRef ?? null;
  const rawBaseCommitRef = payload.baseCommitRef ?? null;

  if (!rawHeadCommitRef) {
    throw new Error("headCommitRef is required to start a code review");
  }
  if (jobType === "pull_request" && !rawBaseCommitRef) {
    throw new Error("baseCommitRef is required for pull request code reviews");
  }
  if (jobType === "comparison" && !rawBaseCommitRef) {
    throw new Error("baseCommitRef is required for comparison code reviews");
  }

  const headCommitRef = rawHeadCommitRef;
  const baseCommitRef = rawBaseCommitRef as string;

  const convex = getConvex({ accessToken });
  const callbackToken = randomBytes(32).toString("hex");
  const callbackTokenHash = hashCallbackToken(callbackToken);
  console.info("[code-review] Generated callback token", {
    githubLink: payload.githubLink,
    tokenPreview: callbackToken.slice(0, 8),
  });

  const reserveResult = await convex.mutation(api.codeReview.reserveJob, {
    teamSlugOrId: payload.teamSlugOrId,
    githubLink: payload.githubLink,
    prNumber: payload.prNumber,
    commitRef: headCommitRef,
    headCommitRef,
    baseCommitRef,
    callbackTokenHash,
    force: payload.force,
    comparison: payload.comparison
      ? {
          slug: payload.comparison.slug,
          baseOwner: payload.comparison.base.owner,
          baseRef: payload.comparison.base.ref,
          headOwner: payload.comparison.head.owner,
          headRef: payload.comparison.head.ref,
        }
      : undefined,
  });

  if (!reserveResult.wasCreated) {
    console.info("[code-review] Reusing existing job from reserve", {
      jobId: reserveResult.job.jobId,
      repoFullName: reserveResult.job.repoFullName,
      prNumber: reserveResult.job.prNumber,
      commitRef: reserveResult.job.commitRef,
      baseCommitRef: reserveResult.job.baseCommitRef,
    });
    return {
      job: normalizeJob(reserveResult.job),
      deduplicated: true,
      backgroundTask: null,
    };
  }

  console.info("[code-review] Created new job via reserve", {
    jobId: reserveResult.job.jobId,
    repoFullName: reserveResult.job.repoFullName,
    prNumber: reserveResult.job.prNumber,
    commitRef: reserveResult.job.commitRef,
    baseCommitRef: reserveResult.job.baseCommitRef,
  });

  const rawJob = reserveResult.job;
  const job = normalizeJob(rawJob);
  console.info("[code-review] Callback token associated with job", {
    jobId: job.jobId,
    tokenPreview: callbackToken.slice(0, 8),
  });
  const callbackUrl = `${callbackBaseUrl}/api/code-review/callback`;
  const fileCallbackUrl = `${callbackBaseUrl}/api/code-review/file-callback`;

  const runningJobRaw = await convex.mutation(api.codeReview.markJobRunning, {
    jobId: rawJob.jobId as Id<"automatedCodeReviewJobs">,
  });
  const runningJob = normalizeJob(runningJobRaw);

  console.info("[code-review] Dispatching background review", {
    jobId: runningJob.jobId,
    repoFullName: runningJob.repoFullName,
    prNumber: runningJob.prNumber,
    callbackTokenPreview: callbackToken.slice(0, 8),
  });

  const reviewConfig: PrReviewJobContext = {
    jobId: job.jobId,
    teamId: job.teamId ?? undefined,
    repoFullName: job.repoFullName,
    repoUrl: job.repoUrl,
    prNumber: job.prNumber ?? undefined,
    prUrl: payload.githubLink,
    commitRef: job.commitRef,
    comparison: deriveComparisonContext(job),
    callback: {
      url: callbackUrl,
      token: callbackToken,
    },
    fileCallback: {
      url: fileCallbackUrl,
      token: callbackToken,
    },
    strategy,
    githubAccessToken: githubAccessToken ?? undefined,
  };

  const backgroundTask = (async () => {
    try {
      // Fork based on strategy
      if (strategy === "heatmap") {
        console.info("[code-review] Starting heatmap review (no Morph)", {
          jobId: job.jobId,
          strategy: "heatmap",
        });
        await runHeatmapReview({
          jobId: job.jobId,
          teamId: job.teamId ?? undefined,
          prUrl: payload.githubLink,
          prNumber: job.prNumber ?? undefined,
          accessToken,
          callbackToken,
          githubAccessToken,
        });
      } else {
        console.info("[code-review] Starting automated PR review (Morph)", {
          jobId: job.jobId,
          strategy,
        });
        await startAutomatedPrReview(reviewConfig);
      }
      console.info("[code-review] Review completed", {
        jobId: job.jobId,
        strategy,
        callbackTokenPreview: callbackToken.slice(0, 8),
      });
    } catch (error) {
      const message =
        error instanceof Error ? error.message : String(error ?? "Unknown error");
      console.error("[code-review] Background review failed", message);

      try {
        await convex.mutation(api.codeReview.failJob, {
          jobId: job.jobId as Id<"automatedCodeReviewJobs">,
          errorCode: "pr_review_setup_failed",
          errorDetail: message,
        });
      } catch (failError) {
        const failMessage =
          failError instanceof Error
            ? failError.message
            : String(failError ?? "Unknown failJob error");
        console.error(
          "[code-review] Failed to mark job as failed after background error",
          failMessage,
        );
      }
    }
  })();

  return {
    job: runningJob,
    deduplicated: false,
    backgroundTask,
  };
}

type RawJob = {
  jobId: string;
  teamId?: string | null;
  [key: string]: unknown;
};

function normalizeJob(job: RawJob): StartCodeReviewResult["job"] {
  return {
    ...job,
    teamId: job.teamId ?? null,
    sharingScope:
      (job.sharingScope as "team" | "shared" | undefined) ?? "team",
    prNumber: (job.prNumber as number | undefined) ?? null,
    headCommitRef:
      (job.headCommitRef as string | undefined) ??
      (job.commitRef as string),
    baseCommitRef:
      (job.baseCommitRef as string | null | undefined) ?? null,
    jobType:
      (job.jobType as StartCodeReviewResult["job"]["jobType"]) ?? "pull_request",
    comparisonSlug:
      (job.comparisonSlug as string | null | undefined) ?? null,
    comparisonBaseOwner:
      (job.comparisonBaseOwner as string | null | undefined) ?? null,
    comparisonBaseRef:
      (job.comparisonBaseRef as string | null | undefined) ?? null,
    comparisonHeadOwner:
      (job.comparisonHeadOwner as string | null | undefined) ?? null,
    comparisonHeadRef:
      (job.comparisonHeadRef as string | null | undefined) ?? null,
  } as StartCodeReviewResult["job"];
}

function deriveComparisonContext(
  job: StartCodeReviewResult["job"]
): PrReviewJobContext["comparison"] {
  if (job.jobType !== "comparison") {
    return undefined;
  }

  const baseOwner =
    job.comparisonBaseOwner ??
    job.repoFullName.split("/")[0] ??
    undefined;
  const baseRef = job.comparisonBaseRef ?? undefined;
  const headOwner =
    job.comparisonHeadOwner ?? baseOwner ?? undefined;
  const headRef = job.comparisonHeadRef ?? undefined;
  const slug = job.comparisonSlug ?? undefined;

  if (!baseOwner || !baseRef || !headOwner || !headRef || !slug) {
    console.warn(
      "[code-review] Comparison job missing required fields; skipping comparison context",
      {
        jobId: job.jobId,
        baseOwner,
        baseRef,
        headOwner,
        headRef,
        slug,
      }
    );
    return undefined;
  }

  return {
    slug,
    baseOwner,
    baseRef,
    headOwner,
    headRef,
  };
}
