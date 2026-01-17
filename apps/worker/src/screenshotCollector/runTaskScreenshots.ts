import type { ScreenshotUploadPayload } from "@cmux/shared";
import type { Id } from "@cmux/convex/dataModel";
import { promises as fs } from "node:fs";
import * as path from "node:path";

import { log } from "../logger";
import { startScreenshotCollection } from "./startScreenshotCollection";
import { createScreenshotUploadUrl, uploadScreenshot } from "./upload";

export interface RunTaskScreenshotsOptions {
  taskId: Id<"tasks">;
  taskRunId: Id<"taskRuns">;
  token: string;
  convexUrl?: string;
  anthropicApiKey?: string | null;
  taskRunJwt?: string | null;
  /** Command to install dependencies (e.g., "bun install") */
  installCommand?: string | null;
  /** Command to start the dev server (e.g., "bun run dev") */
  devCommand?: string | null;
}

function resolveImageContentType(filePath: string): string {
  const extension = path.extname(filePath).toLowerCase();
  if (extension === ".jpg" || extension === ".jpeg") {
    return "image/jpeg";
  }
  if (extension === ".webp") {
    return "image/webp";
  }
  return "image/png";
}

function resolveVideoContentType(filePath: string): string {
  const extension = path.extname(filePath).toLowerCase();
  if (extension === ".webm") {
    return "video/webm";
  }
  if (extension === ".mkv") {
    return "video/x-matroska";
  }
  if (extension === ".gif") {
    return "image/gif";
  }
  return "video/mp4";
}

async function uploadScreenshotFile(params: {
  screenshotPath: string;
  fileName?: string;
  commitSha: string;
  token: string;
  convexUrl?: string;
  description?: string;
}): Promise<NonNullable<ScreenshotUploadPayload["images"]>[number]> {
  const { screenshotPath, fileName, commitSha, token, convexUrl, description } =
    params;
  const resolvedFileName = fileName ?? path.basename(screenshotPath);
  const contentType = resolveImageContentType(screenshotPath);

  const uploadUrl = await createScreenshotUploadUrl({
    token,
    baseUrlOverride: convexUrl,
    contentType,
  });

  const bytes = await fs.readFile(screenshotPath);
  const uploadResponse = await fetch(uploadUrl, {
    method: "POST",
    headers: {
      "Content-Type": contentType,
    },
    body: new Uint8Array(bytes),
  });

  if (!uploadResponse.ok) {
    const body = await uploadResponse.text();
    throw new Error(
      `Upload failed with status ${uploadResponse.status}: ${body}`
    );
  }

  const uploadResult = (await uploadResponse.json()) as {
    storageId?: string;
  };
  if (!uploadResult.storageId) {
    throw new Error("Upload response missing storageId");
  }

  return {
    storageId: uploadResult.storageId,
    mimeType: contentType,
    fileName: resolvedFileName,
    commitSha,
    description,
  };
}

async function uploadVideoFile(params: {
  videoPath: string;
  fileName?: string;
  commitSha: string;
  token: string;
  convexUrl?: string;
  description?: string;
}): Promise<NonNullable<ScreenshotUploadPayload["videos"]>[number]> {
  const { videoPath, fileName, commitSha, token, convexUrl, description } =
    params;
  const resolvedFileName = fileName ?? path.basename(videoPath);
  const contentType = resolveVideoContentType(videoPath);

  const uploadUrl = await createScreenshotUploadUrl({
    token,
    baseUrlOverride: convexUrl,
    contentType,
  });

  const bytes = await fs.readFile(videoPath);
  const uploadResponse = await fetch(uploadUrl, {
    method: "POST",
    headers: {
      "Content-Type": contentType,
    },
    body: new Uint8Array(bytes),
  });

  if (!uploadResponse.ok) {
    const body = await uploadResponse.text();
    throw new Error(
      `Video upload failed with status ${uploadResponse.status}: ${body}`
    );
  }

  const uploadResult = (await uploadResponse.json()) as {
    storageId?: string;
  };
  if (!uploadResult.storageId) {
    throw new Error("Video upload response missing storageId");
  }

  return {
    storageId: uploadResult.storageId,
    mimeType: contentType,
    fileName: resolvedFileName,
    commitSha,
    description,
  };
}

export async function runTaskScreenshots(
  options: RunTaskScreenshotsOptions
): Promise<void> {
  const { taskId, taskRunId, token, convexUrl, anthropicApiKey } = options;
  const taskRunJwt = options.taskRunJwt ?? token;

  log("INFO", "Starting automated screenshot workflow", {
    taskId,
    taskRunId,
    hasAnthropicKey: Boolean(anthropicApiKey ?? process.env.ANTHROPIC_API_KEY),
  });

  const result = await startScreenshotCollection({
    anthropicApiKey: anthropicApiKey ?? undefined,
    taskRunJwt,
    convexUrl,
    installCommand: options.installCommand,
    devCommand: options.devCommand,
  });

  let images: ScreenshotUploadPayload["images"];
  let videos: ScreenshotUploadPayload["videos"];
  let hasUiChanges: boolean | undefined;
  let status: ScreenshotUploadPayload["status"] = "failed";
  let error: string | undefined;
  let commitSha: string | undefined;

  if (result.status === "completed") {
    commitSha = result.commitSha;
    const capturedScreens = result.screenshots ?? [];
    const capturedVideos = result.videos ?? [];
    hasUiChanges = result.hasUiChanges;

    // Allow completion if we have either screenshots or videos
    if (capturedScreens.length === 0 && capturedVideos.length === 0) {
      status = "failed";
      error = "Claude collector returned no screenshots or videos";
      log("ERROR", error, { taskRunId });
    } else {
      // Upload screenshots
      const screenshotUploadPromises = capturedScreens.map((screenshot) =>
        uploadScreenshotFile({
          screenshotPath: screenshot.path,
          fileName: screenshot.fileName,
          commitSha: result.commitSha,
          token,
          convexUrl,
          description: screenshot.description,
        })
      );

      // Upload videos
      const videoUploadPromises = capturedVideos.map((video) =>
        uploadVideoFile({
          videoPath: video.path,
          fileName: video.fileName,
          commitSha: result.commitSha,
          token,
          convexUrl,
          description: video.description,
        })
      );

      const [settledScreenshots, settledVideos] = await Promise.all([
        Promise.allSettled(screenshotUploadPromises),
        Promise.allSettled(videoUploadPromises),
      ]);

      const successfulScreens: NonNullable<ScreenshotUploadPayload["images"]> = [];
      const successfulVideos: NonNullable<ScreenshotUploadPayload["videos"]> = [];
      const failures: { type: string; index: number; reason: string }[] = [];

      settledScreenshots.forEach((settled, index) => {
        if (settled.status === "fulfilled") {
          successfulScreens.push(settled.value);
        } else {
          const reason =
            settled.reason instanceof Error
              ? settled.reason.message
              : String(settled.reason);
          failures.push({ type: "screenshot", index, reason });
          log("ERROR", "Failed to upload screenshot", {
            taskRunId,
            screenshotPath: capturedScreens[index]?.path,
            error: reason,
          });
        }
      });

      settledVideos.forEach((settled, index) => {
        if (settled.status === "fulfilled") {
          successfulVideos.push(settled.value);
        } else {
          const reason =
            settled.reason instanceof Error
              ? settled.reason.message
              : String(settled.reason);
          failures.push({ type: "video", index, reason });
          log("ERROR", "Failed to upload video", {
            taskRunId,
            videoPath: capturedVideos[index]?.path,
            error: reason,
          });
        }
      });

      if (failures.length === 0) {
        images = successfulScreens.length > 0 ? successfulScreens : undefined;
        videos = successfulVideos.length > 0 ? successfulVideos : undefined;
        status = "completed";
        log("INFO", "Media uploaded", {
          taskRunId,
          screenshotCount: successfulScreens.length,
          videoCount: successfulVideos.length,
          commitSha: result.commitSha,
        });
      } else {
        status = "failed";
        error =
          failures.length === 1 && failures[0]
            ? failures[0].reason
            : `Failed to upload ${failures.length} media files`;
      }
    }
  } else if (result.status === "skipped") {
    status = "skipped";
    error = result.reason;
    commitSha = result.commitSha;
    hasUiChanges = result.hasUiChanges;
    log("INFO", "Screenshot workflow skipped", {
      taskRunId,
      reason: result.reason,
    });
  } else if (result.status === "failed") {
    status = "failed";
    error = result.error;
    commitSha = result.commitSha;
    hasUiChanges = result.hasUiChanges;
    log("ERROR", "Screenshot workflow failed", {
      taskRunId,
      error: result.error,
    });
  } else {
    status = "failed";
    error = "Unknown screenshot workflow result";
    log("ERROR", "Screenshot workflow returned unknown status", {
      taskRunId,
      result,
    });
  }
  // For completed status, commitSha is required
  if (status === "completed" && !commitSha) {
    log("ERROR", "Cannot upload completed screenshot result without commitSha", {
      taskRunId,
      status,
      error,
    });
    return;
  }

  await uploadScreenshot({
    token,
    baseUrlOverride: convexUrl,
    payload: {
      taskId,
      runId: taskRunId,
      status,
      // Only include commitSha if available (required for completed, optional for failed/skipped)
      ...(commitSha && { commitSha }),
      images,
      videos,
      error,
      hasUiChanges,
    },
  });
}
