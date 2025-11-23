import { startBrowserAgent } from "magnitude-core";

import { ACTION_FORMAT_PROMPT } from "./agentActionPrompt";

const SKIP_AGENT_STOP = process.env.BROWSER_AGENT_SKIP_STOP === "1";
const REQUESTED_SCREENSHOT_PATH =
  process.env.BROWSER_AGENT_SCREENSHOT_PATH?.trim();

const DEFAULT_CDP_ENDPOINT = "http://127.0.0.1:39382";

interface DevtoolsVersionResponse {
  readonly webSocketDebuggerUrl: string;
}

type BrowserAgent = Awaited<ReturnType<typeof startBrowserAgent>>;

function parsePrompt(args: readonly string[]): string {
  let prompt = "";

  for (let index = 0; index < args.length; index += 1) {
    const token = args[index];
    if (typeof token === "undefined") {
      continue;
    }
    if (token === "--prompt") {
      const next = args[index + 1];
      if (typeof next !== "string") {
        throw new Error("--prompt requires a value");
      }
      prompt = next;
      index += 1;
      continue;
    }
    if (token.startsWith("--prompt=")) {
      prompt = token.slice("--prompt=".length);
      continue;
    }
  }

  if (prompt.trim().length === 0) {
    const envPrompt = process.env.BROWSER_AGENT_PROMPT?.trim();
    if (envPrompt && envPrompt.length > 0) {
      prompt = envPrompt;
    }
  }

  if (prompt.trim().length === 0) {
    throw new Error(
      'Prompt is required. Pass --prompt "<instructions>" or set BROWSER_AGENT_PROMPT.'
    );
  }

  return prompt;
}

async function fetchWebSocketUrl(endpoint: string): Promise<string> {
  const versionUrl = new URL("/json/version", endpoint);
  const response = await fetch(versionUrl);

  if (!response.ok) {
    throw new Error(
      `Failed to load CDP version info (${response.status} ${response.statusText})`
    );
  }

  const payload = (await response.json()) as unknown;
  if (
    typeof payload !== "object" ||
    payload === null ||
    typeof (payload as Partial<DevtoolsVersionResponse>)
      .webSocketDebuggerUrl !== "string"
  ) {
    throw new Error("Invalid CDP version response (missing websocket URL)");
  }

  return (payload as DevtoolsVersionResponse).webSocketDebuggerUrl;
}

async function resolveCdpWebSocketUrl(
  endpoint: string,
  options: { attempts?: number; delayMs?: number } = {}
): Promise<string> {
  const attempts = options.attempts ?? 30;
  const delayMs = options.delayMs ?? 1000;
  let lastError: unknown;

  for (let attempt = 1; attempt <= attempts; attempt += 1) {
    try {
      console.log(
        `[runBrowserAgentFromPrompt] Resolving CDP websocket (attempt ${attempt}/${attempts})`
      );
      return await fetchWebSocketUrl(endpoint);
    } catch (error) {
      lastError = error;
      if (attempt < attempts) {
        await new Promise((resolve) => setTimeout(resolve, delayMs));
      }
    }
  }

  const reason =
    lastError instanceof Error
      ? lastError.message
      : String(lastError ?? "unknown error");

  throw new Error(
    `Failed to resolve CDP websocket after ${attempts} attempts: ${reason}`
  );
}

async function refreshPageBeforeScreenshot(
  agent: BrowserAgent
): Promise<void> {
  console.log(
    "[runBrowserAgentFromPrompt] Refreshing page before screenshot capture"
  );
  try {
    await agent.page.reload({ waitUntil: "networkidle" });
    console.log(
      "[runBrowserAgentFromPrompt] Page refresh completed. Proceeding to capture screenshot."
    );
  } catch (refreshError) {
    const reason =
      refreshError instanceof Error
        ? refreshError.message
        : String(refreshError ?? "unknown refresh error");
    console.error(
      `[runBrowserAgentFromPrompt] Failed to refresh page before screenshot: ${reason}`
    );
  }
}

async function captureScreenshotIfRequested(
  agent: BrowserAgent
): Promise<void> {
  if (!REQUESTED_SCREENSHOT_PATH) {
    return;
  }

  await refreshPageBeforeScreenshot(agent);

  try {
    await agent.page.screenshot({
      path: REQUESTED_SCREENSHOT_PATH,
      type: "png",
      fullPage: true,
    });
    console.log(
      `[runBrowserAgentFromPrompt] Screenshot captured to ${REQUESTED_SCREENSHOT_PATH}`
    );
  } catch (screenshotError) {
    const reason =
      screenshotError instanceof Error
        ? screenshotError.message
        : String(screenshotError ?? "unknown screenshot error");
    console.error(
      `[runBrowserAgentFromPrompt] Failed to capture screenshot: ${reason}`
    );
  }
}

async function main(): Promise<void> {
  const prompt = parsePrompt(process.argv.slice(2));

  const anthropicApiKey = process.env.ANTHROPIC_API_KEY?.trim();
  if (!anthropicApiKey) {
    throw new Error(
      "ANTHROPIC_API_KEY is not set. Populate it in the environment or .env."
    );
  }

  const rawCdpEndpoint = process.env.CDP_ENDPOINT?.trim();
  const cdpEndpoint =
    rawCdpEndpoint && rawCdpEndpoint.length > 0
      ? rawCdpEndpoint
      : DEFAULT_CDP_ENDPOINT;

  console.log(
    `[runBrowserAgentFromPrompt] Using CDP HTTP endpoint: ${cdpEndpoint}`
  );

  const cdpWebSocketUrl = await resolveCdpWebSocketUrl(cdpEndpoint);
  console.log(
    `[runBrowserAgentFromPrompt] Resolved websocket endpoint: ${cdpWebSocketUrl}`
  );

  const agent = await startBrowserAgent({
    llm: {
      provider: "anthropic",
      options: {
        model: "claude-sonnet-4-5",
        apiKey: anthropicApiKey,
      },
    },
    browser: {
      cdp: cdpWebSocketUrl,
    },
    prompt: ACTION_FORMAT_PROMPT,
  });
  await agent.act(prompt);
  await captureScreenshotIfRequested(agent);
  if (!SKIP_AGENT_STOP) {
    await agent.stop();
  }
}

(async () => {
  try {
    await main();
    process.exit(0);
  } catch (error) {
    const reason =
      error instanceof Error ? error.message : String(error ?? "unknown error");
    console.error(`[runBrowserAgentFromPrompt] ${reason}`);
    process.exit(1);
  }
})();
