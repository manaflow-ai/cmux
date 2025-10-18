import { randomBytes, createHash } from "node:crypto";
import { ConvexHttpClient } from "convex/browser";
import { api } from "@cmux/convex/api";
import type { Id } from "@cmux/convex/dataModel";

import { getConvex } from "@/lib/utils/get-convex";
import { verifyTeamAccess } from "@/lib/utils/team-verification";
import { env } from "@/lib/utils/www-env";
import {
  startAutomatedPrReview,
  type PrReviewJobContext,
} from "@/src/pr-review";

type StartCodeReviewPayload = {
  teamSlugOrId?: string;
  githubLink: string;
  prNumber: number;
  commitRef?: string;
  force?: boolean;
};

type StartCodeReviewOptions = {
  accessToken: string;
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
    prNumber: number;
    commitRef: string;
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
  };
  deduplicated: boolean;
  backgroundTask: Promise<void> | null;
};

function hashCallbackToken(token: string): string {
  return createHash("sha256").update(token).digest("hex");
}

export function getConvexHttpActionBaseUrl(): string | null {
  const url = env.NEXT_PUBLIC_CONVEX_URL;
  if (!url) {
    return null;
  }
  return url.replace(".convex.cloud", ".convex.site").replace(/\/$/, "");
}

function getDeployConvexClient(): ConvexHttpClient {
  const client = new ConvexHttpClient(env.NEXT_PUBLIC_CONVEX_URL);
  client.setAuth(env.CONVEX_DEPLOY_KEY);
  return client;
}

export async function startCodeReviewJob({
  accessToken,
  callbackBaseUrl,
  payload,
  request,
}: StartCodeReviewOptions): Promise<StartCodeReviewResult> {
  if (payload.teamSlugOrId) {
    try {
      await verifyTeamAccess({
        accessToken,
        req: request,
        teamSlugOrId: payload.teamSlugOrId,
      });
    } catch (error) {
      console.warn("[code-review] Proceeding without verified team access", {
        teamSlugOrId: payload.teamSlugOrId,
        error,
      });
    }
  } else {
    const inferredSlug = payload.githubLink.split("/")[3] ?? "unknown";
    console.info("[code-review] No team slug provided; using repo owner from URL", {
      inferredSlug,
      githubLink: payload.githubLink,
    });
  }

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
    commitRef: payload.commitRef,
    callbackTokenHash,
    force: payload.force,
  });

  if (!reserveResult.wasCreated) {
    console.info("[code-review] Reusing existing job from reserve", {
      jobId: reserveResult.job.jobId,
      repoFullName: reserveResult.job.repoFullName,
      prNumber: reserveResult.job.prNumber,
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
    prNumber: job.prNumber,
    prUrl: payload.githubLink,
    commitRef: job.commitRef,
    callback: {
      url: callbackUrl,
      token: callbackToken,
    },
    fileCallback: {
      url: fileCallbackUrl,
      token: callbackToken,
    },
  };

  const backgroundTask = (async () => {
    try {
      console.info("[code-review] Starting automated PR review", {
        jobId: job.jobId,
      });
      await startAutomatedPrReview(reviewConfig);
      console.info("[code-review] Automated PR review completed", {
        jobId: job.jobId,
        callbackTokenPreview: callbackToken.slice(0, 8),
      });
    } catch (error) {
      const message =
        error instanceof Error ? error.message : String(error ?? "Unknown error");
      console.error("[code-review] Background review failed", message);

      const deployConvex = getDeployConvexClient();
      try {
        await deployConvex.mutation(api.codeReview.failJob, {
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
  } as StartCodeReviewResult["job"];
}
