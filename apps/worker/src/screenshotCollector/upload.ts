import type { ScreenshotUploadPayload, ScreenshotUploadResponse } from "@cmux/shared";

import { convexRequest } from "../crown/convex";
import { log } from "../logger";

interface UploadScreenshotOptions {
  token: string;
  payload: ScreenshotUploadPayload;
  baseUrlOverride?: string;
}

export async function uploadScreenshot(
  options: UploadScreenshotOptions,
): Promise<void> {
  const response = await convexRequest<ScreenshotUploadResponse>(
    "/api/screenshots/upload",
    options.token,
    options.payload,
    options.baseUrlOverride,
  );

  if (!response?.ok) {
    log("ERROR", "Failed to upload screenshot metadata", {
      taskId: options.payload.taskId,
      taskRunId: options.payload.runId,
    });
  } else {
    log("INFO", "Screenshot metadata uploaded", {
      taskId: options.payload.taskId,
      taskRunId: options.payload.runId,
      storageId: response.storageId,
      status: options.payload.status,
    });
  }
}
