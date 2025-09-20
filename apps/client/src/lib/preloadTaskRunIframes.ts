import { persistentIframeManager } from "./persistentIframeManager";
import { getTaskRunPersistKey } from "./persistent-webview-keys";

/**
 * Preload iframes for task runs
 * @param taskRunIds - Array of task run IDs to preload
 * @returns Promise that resolves when all iframes are loaded
 */
export async function preloadTaskRunIframes(
  data: { url: string; taskRunId: string }[]
): Promise<void> {
  const entries = data.map(({ url, taskRunId }) => {
    const key = getTaskRunPersistKey(taskRunId);
    return {
      key,
      url,
      allow: "clipboard-read; clipboard-write",
      sandbox:
        "allow-forms allow-modals allow-orientation-lock allow-pointer-lock allow-popups allow-popups-to-escape-sandbox allow-presentation allow-same-origin allow-scripts allow-top-navigation",
    };
  });

  await persistentIframeManager.preloadMultiple(entries);
}

/**
 * Preload a single task run iframe
 * @param taskRunId - Task run ID to preload
 * @returns Promise that resolves when the iframe is loaded
 */
export async function preloadTaskRunIframe(
  taskRunId: string,
  url: string
): Promise<void> {
  await persistentIframeManager.preloadIframe(getTaskRunPersistKey(taskRunId), url, {
    allow: "clipboard-read; clipboard-write",
    sandbox:
      "allow-forms allow-modals allow-orientation-lock allow-pointer-lock allow-popups allow-popups-to-escape-sandbox allow-presentation allow-same-origin allow-scripts allow-top-navigation",
  });
}

/**
 * Remove a task run iframe from memory
 * @param taskRunId - Task run ID to remove
 */
export function removeTaskRunIframe(taskRunId: string): void {
  persistentIframeManager.removeIframe(getTaskRunPersistKey(taskRunId));
}

/**
 * Get all currently loaded task run iframe keys
 * @returns Array of task run IDs that have loaded iframes
 */
export function getLoadedTaskRunIframes(): string[] {
  return persistentIframeManager
    .getLoadedKeys()
    .filter((key) => key.startsWith("task-run:"))
    .map((key) => key.replace("task-run:", ""));
}
