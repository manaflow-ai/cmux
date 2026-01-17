import { promises as fs } from "node:fs";
import * as path from "node:path";
import * as os from "node:os";

import { log } from "../logger";

/** Auth config for Claude Code screenshot collection */
export type ClaudeCodeAuthConfig =
  | { auth: { taskRunJwt: string } }
  | { auth: { anthropicApiKey: string } };

/** Result from screenshot collection */
export interface ScreenshotResult {
  status: "completed" | "failed" | "skipped";
  screenshots?: { path: string; description?: string }[];
  videos?: { path: string; description?: string }[];
  hasUiChanges?: boolean;
  error?: string;
  reason?: string;
}

/** Options for capturing PR screenshots */
export type CaptureScreenshotsOptions = {
  workspaceDir: string;
  changedFiles: string[];
  prTitle: string;
  prDescription: string;
  outputDir: string;
  baseBranch: string;
  headBranch: string;
  pathToClaudeCodeExecutable?: string;
  installCommand?: string;
  devCommand?: string;
  convexSiteUrl?: string;
} & ({ auth: { taskRunJwt: string } } | { auth: { anthropicApiKey: string } });

export interface ScreenshotCollectorModule {
  claudeCodeCapturePRScreenshots: (options: CaptureScreenshotsOptions) => Promise<ScreenshotResult>;
  normalizeScreenshotOutputDir: (outputDir: string) => string;
  SCREENSHOT_STORAGE_ROOT: string;
}

/**
 * Determines if we're running in staging mode.
 * Defaults to false (production) unless explicitly set via CMUX_IS_STAGING=true.
 *
 * Note: We default to production because:
 * 1. Morph sandboxes don't have NODE_ENV=production set
 * 2. Production Convex only has production releases (isStaging=false)
 * 3. Staging should be an explicit opt-in, not a default
 */
export function isStaging(): boolean {
  return process.env.CMUX_IS_STAGING === "true";
}

/**
 * Gets the Convex site URL for HTTP endpoints.
 * Note: HTTP endpoints require the .site URL, not .cloud URL
 */
function getConvexSiteUrl(providedUrl?: string): string | null {
  // Use provided URL first (from API call)
  if (providedUrl) {
    // Convert .cloud URL to .site URL if needed
    return providedUrl.replace(".convex.cloud", ".convex.site").replace(/\/$/, "");
  }

  // CONVEX_SITE_URL should be the .site URL for HTTP endpoints
  if (process.env.CONVEX_SITE_URL) {
    return process.env.CONVEX_SITE_URL;
  }

  // Try to convert .cloud URL to .site URL
  const cloudUrl = process.env.CONVEX_URL || process.env.NEXT_PUBLIC_CONVEX_URL;
  if (cloudUrl) {
    // Convert https://xxx.convex.cloud to https://xxx.convex.site
    return cloudUrl.replace(".convex.cloud", ".convex.site");
  }

  return null;
}

/**
 * Downloads the latest screenshot collector from Convex storage
 */
async function downloadScreenshotCollector(providedConvexUrl?: string): Promise<string> {
  const convexUrl = getConvexSiteUrl(providedConvexUrl);
  if (!convexUrl) {
    throw new Error(
      "Convex URL is required to fetch screenshot collector. " +
      "Pass convexUrl to loadScreenshotCollector() or set CONVEX_SITE_URL/CONVEX_URL environment variable."
    );
  }

  const staging = isStaging();
  const endpoint = `${convexUrl}/api/host-screenshot-collector/latest?staging=${staging}`;

  log("INFO", "Fetching screenshot collector from Convex", {
    endpoint,
    isStaging: staging,
  });

  const response = await fetch(endpoint);
  if (!response.ok) {
    const errorText = await response.text();
    log("ERROR", "Failed to fetch screenshot collector info from Convex", {
      status: response.status,
      error: errorText,
    });
    throw new Error(
      `Failed to fetch screenshot collector info from Convex (${response.status}): ${errorText}`
    );
  }

  const releaseInfo = await response.json();
  if (!releaseInfo.url) {
    log("ERROR", "No URL in screenshot collector release info", {
      releaseInfo,
    });
    throw new Error("No URL in screenshot collector release info from Convex");
  }

  log("INFO", "Found screenshot collector release", {
    version: releaseInfo.version,
    commitSha: releaseInfo.commitSha,
    url: releaseInfo.url,
  });

  // Download the actual JS file
  const jsResponse = await fetch(releaseInfo.url);
  if (!jsResponse.ok) {
    log("ERROR", "Failed to download screenshot collector JS", {
      status: jsResponse.status,
      url: releaseInfo.url,
    });
    throw new Error(
      `Failed to download screenshot collector JS (${jsResponse.status}) from ${releaseInfo.url}`
    );
  }

  const jsContent = await jsResponse.text();

  // Save to a temp file for dynamic import
  const tempDir = path.join(os.tmpdir(), "cmux-screenshot-collector");
  await fs.mkdir(tempDir, { recursive: true });

  const tempFile = path.join(tempDir, `collector-${releaseInfo.version}.mjs`);

  // Check if we already have this version cached
  try {
    await fs.access(tempFile);
    log("INFO", "Using cached screenshot collector", {
      version: releaseInfo.version,
      path: tempFile,
    });
    return tempFile;
  } catch {
    // File doesn't exist, write it
  }

  await fs.writeFile(tempFile, jsContent);
  log("INFO", "Downloaded and cached screenshot collector", {
    version: releaseInfo.version,
    path: tempFile,
    size: jsContent.length,
  });

  return tempFile;
}

let cachedModule: ScreenshotCollectorModule | null = null;

/**
 * Loads the screenshot collector module from Convex storage.
 *
 * @param convexUrl - The Convex site URL for fetching the remote screenshot collector.
 *                    Falls back to environment variables if not provided.
 * @throws Error if the screenshot collector cannot be fetched or loaded.
 */
export async function loadScreenshotCollector(convexUrl?: string): Promise<ScreenshotCollectorModule> {
  // Return cached module if available
  if (cachedModule) {
    return cachedModule;
  }

  // Download the latest version from Convex (throws on failure)
  const remotePath = await downloadScreenshotCollector(convexUrl);

  // Use file:// URL for dynamic import
  const moduleUrl = `file://${remotePath}`;
  const remoteModule = await import(moduleUrl);

  log("INFO", "Successfully loaded remote screenshot collector", {
    path: remotePath,
  });

  cachedModule = remoteModule as ScreenshotCollectorModule;
  return cachedModule;
}

/**
 * Clears the cached module (useful for testing or forcing a refresh)
 */
export function clearScreenshotCollectorCache(): void {
  cachedModule = null;
}
