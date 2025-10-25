import { queryOptions } from "@tanstack/react-query";

export type TerminalTabId = string;

export interface CreateTerminalTabRequest {
  cmd?: string;
  args?: string[];
  cols?: number;
  rows?: number;
}

export interface CreateTerminalTabResponse {
  id: string;
  wsUrl: string;
}

const NO_BASE_PLACEHOLDER = "__no-terminal-base__";
const NO_CONTEXT_PLACEHOLDER = "__no-terminal-context__";

export function terminalTabsQueryKey(
  baseUrl: string | null | undefined,
  contextKey?: string | number | null
) {
  return [
    "terminal-tabs",
    contextKey ?? NO_CONTEXT_PLACEHOLDER,
    baseUrl ?? NO_BASE_PLACEHOLDER,
    "list",
  ] as const;
}

function ensureBaseUrl(baseUrl: string | null | undefined): string {
  if (!baseUrl) {
    throw new Error("Terminal backend is not ready yet.");
  }
  return baseUrl;
}

function buildTerminalUrl(baseUrl: string, pathname: string) {
  return new URL(pathname, baseUrl);
}

function isTerminalTabIdList(value: unknown): value is TerminalTabId[] {
  return (
    Array.isArray(value) && value.every((entry) => typeof entry === "string")
  );
}

interface CreateTerminalTabHttpResponse {
  id: string;
  ws_url: string;
}

function isCreateTerminalTabHttpResponse(
  value: unknown
): value is CreateTerminalTabHttpResponse {
  if (typeof value !== "object" || value === null) {
    return false;
  }
  const id = Reflect.get(value, "id");
  const wsUrl = Reflect.get(value, "ws_url");
  return typeof id === "string" && typeof wsUrl === "string";
}

const DEFAULT_TMUX_ATTACH_TIMEOUT_MS = 15_000;
const DEFAULT_TMUX_ATTACH_INTERVAL_MS = 200;

function formatSleepInterval(intervalMs: number): string {
  const seconds = intervalMs / 1_000;
  return seconds.toFixed(3).replace(/\.?0+$/, "");
}

// Produce a shell command that waits for the tmux session before attaching.
export function buildTmuxAttachRequest(
  sessionName: string,
  options?: {
    timeoutMs?: number;
    checkIntervalMs?: number;
  }
): CreateTerminalTabRequest {
  const timeoutMs = options?.timeoutMs ?? DEFAULT_TMUX_ATTACH_TIMEOUT_MS;
  const checkIntervalMs =
    options?.checkIntervalMs ?? DEFAULT_TMUX_ATTACH_INTERVAL_MS;
  const maxAttempts = Math.max(
    1,
    Math.ceil(timeoutMs / Math.max(1, checkIntervalMs))
  );
  const sleepInterval = formatSleepInterval(checkIntervalMs);
  const sessionLiteral = JSON.stringify(sessionName);

  const script = `
session_name=${sessionLiteral};
max_attempts=${maxAttempts};
sleep_interval=${sleepInterval};
attempt=0;

while ! tmux has-session -t "$session_name" 2>/dev/null; do
  attempt=$((attempt + 1));
  if [ "$attempt" -ge "$max_attempts" ]; then
    echo "tmux session '$session_name' not available yet" >&2;
    exit 1;
  fi;
  sleep "$sleep_interval";
done;

exec tmux attach -t "$session_name";
`.trim();

  return {
    cmd: "bash",
    args: ["-lc", script],
  };
}

export function terminalTabsQueryOptions({
  baseUrl,
  contextKey,
  enabled = true,
}: {
  baseUrl: string | null | undefined;
  contextKey?: string | number | null;
  enabled?: boolean;
}) {
  const effectiveEnabled = Boolean(enabled && baseUrl);

  return queryOptions<TerminalTabId[]>({
    queryKey: terminalTabsQueryKey(baseUrl, contextKey),
    enabled: effectiveEnabled,
    queryFn: async () => {
      const resolvedBaseUrl = ensureBaseUrl(baseUrl);
      const url = buildTerminalUrl(resolvedBaseUrl, "/api/tabs");
      const response = await fetch(url, {
        headers: {
          Accept: "application/json",
        },
      });
      if (!response.ok) {
        throw new Error(`Failed to load terminals (${response.status})`);
      }
      const payload: unknown = await response.json();
      if (!isTerminalTabIdList(payload)) {
        throw new Error("Unexpected response while loading terminals.");
      }
      return payload;
    },
    refetchInterval: 10_000,
    refetchOnWindowFocus: true,
  });
}

export async function createTerminalTab({
  baseUrl,
  request,
}: {
  baseUrl: string | null | undefined;
  request?: CreateTerminalTabRequest;
}): Promise<CreateTerminalTabResponse> {
  const resolvedBaseUrl = ensureBaseUrl(baseUrl);
  const url = buildTerminalUrl(resolvedBaseUrl, "/api/tabs");
  const response = await fetch(url, {
    method: "POST",
    headers: {
      Accept: "application/json",
      "Content-Type": "application/json",
    },
    body: JSON.stringify(request ?? {}),
  });
  if (!response.ok) {
    throw new Error(`Failed to create terminal (${response.status})`);
  }
  const payload: unknown = await response.json();
  if (!isCreateTerminalTabHttpResponse(payload)) {
    throw new Error("Unexpected response while creating terminal.");
  }
  return {
    id: payload.id,
    wsUrl: payload.ws_url,
  };
}

export async function deleteTerminalTab({
  baseUrl,
  tabId,
}: {
  baseUrl: string | null | undefined;
  tabId: string;
}): Promise<void> {
  const resolvedBaseUrl = ensureBaseUrl(baseUrl);
  const url = buildTerminalUrl(
    resolvedBaseUrl,
    `/api/tabs/${encodeURIComponent(tabId)}`
  );
  const response = await fetch(url, {
    method: "DELETE",
    headers: {
      Accept: "application/json",
    },
  });
  if (!response.ok) {
    throw new Error(`Failed to delete terminal (${response.status})`);
  }
}
