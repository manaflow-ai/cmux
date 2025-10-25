export const PLAN_MODE_PENDING_TASK_STORAGE_KEY = "cmux:planMode:pendingTask";

export interface PendingPlanTaskPayload {
  prompt: string;
  repoFullName?: string | null;
  branch?: string | null;
  isCloudMode?: boolean;
  selectedAgents?: string[];
  shouldAutoStart?: boolean;
  title?: string;
}

function safeSessionStorage(): Storage | null {
  if (typeof window === "undefined") {
    return null;
  }
  try {
    return window.sessionStorage;
  } catch (error) {
    console.warn("Session storage unavailable", error);
    return null;
  }
}

export function readPendingPlanTask(): PendingPlanTaskPayload | null {
  const storage = safeSessionStorage();
  if (!storage) {
    return null;
  }
  const raw = storage.getItem(PLAN_MODE_PENDING_TASK_STORAGE_KEY);
  if (!raw) {
    return null;
  }
  try {
    const parsed = JSON.parse(raw) as unknown;
    if (typeof parsed !== "object" || parsed === null) {
      return null;
    }
    const payload = parsed as PendingPlanTaskPayload;
    if (typeof payload.prompt !== "string" || payload.prompt.trim().length === 0) {
      return null;
    }
    return payload;
  } catch (error) {
    console.warn("Failed to parse pending plan task", error);
    return null;
  }
}

export function writePendingPlanTask(payload: PendingPlanTaskPayload): void {
  const storage = safeSessionStorage();
  if (!storage) {
    return;
  }
  storage.setItem(PLAN_MODE_PENDING_TASK_STORAGE_KEY, JSON.stringify(payload));
}

export function clearPendingPlanTask(): void {
  const storage = safeSessionStorage();
  if (!storage) {
    return;
  }
  storage.removeItem(PLAN_MODE_PENDING_TASK_STORAGE_KEY);
}
