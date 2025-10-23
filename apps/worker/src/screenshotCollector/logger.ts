import { promises as fs } from "node:fs";
import { dirname } from "node:path";

export const SCREENSHOT_COLLECTOR_LOG_PATH =
  "/var/log/cmux/screenshot-collector";
export const SCREENSHOT_COLLECTOR_DIRECTORY_URL =
  "http://localhost:39378/?folder=/var/log/cmux";

export async function logToScreenshotCollector(message: string): Promise<void> {
  const timestamp = new Date().toISOString();
  const logMessage = `${timestamp} ${message}\n`;

  await fs.mkdir(dirname(SCREENSHOT_COLLECTOR_LOG_PATH), {
    recursive: true,
  });
  await fs.appendFile(SCREENSHOT_COLLECTOR_LOG_PATH, logMessage, {
    encoding: "utf8",
  });
}
