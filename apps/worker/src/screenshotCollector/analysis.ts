import { Codex, type ThreadEvent, type ThreadItem } from "@openai/codex-sdk";
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { homedir } from "node:os";
import { z } from "zod";

export const screenshotAnalysisSchema = z.object({
  hasUiChanges: z.boolean(),
  uiChangesToScreenshotInstructions: z.string(),
});

export type ScreenshotAnalysis = z.infer<typeof screenshotAnalysisSchema>;

const screenshotAnalysisJsonSchema = {
  type: "object",
  additionalProperties: false,
  required: ["hasUiChanges", "uiChangesToScreenshotInstructions"],
  properties: {
    hasUiChanges: { type: "boolean" },
    uiChangesToScreenshotInstructions: { type: "string" },
  },
} as const;

type LogFn = (message: string) => Promise<void> | void;

type RawThreadItem =
  | ThreadItem
  | {
      item_type?: string;
      text?: string;
      output_json?: unknown;
    };

function resolveItemType(item: RawThreadItem | undefined): string | null {
  if (!item || typeof item !== "object") {
    return null;
  }
  const candidate =
    (item as { type?: unknown }).type ??
    (item as { item_type?: unknown }).item_type;
  return typeof candidate === "string" ? candidate : null;
}

function describeThreadItem(item: RawThreadItem): string {
  const itemType = resolveItemType(item);
  const status =
    item && typeof item === "object" && "status" in item
      ? String((item as { status?: unknown }).status ?? "unknown")
      : "unknown";
  switch (itemType) {
    case "agent_message":
      return "agent_message";
    case "assistant_message":
      return "assistant_message";
    case "command_execution":
      return `command_execution:${status}`;
    case "file_change":
      return `file_change:${status}`;
    case "mcp_tool_call":
      return `mcp_tool_call:${status}`;
    case "reasoning":
      return "reasoning";
    case "todo_list":
      return "todo_list";
    case "web_search":
      return "web_search";
    case "error":
      return "error";
    default:
      return itemType ?? "unknown";
  }
}

function describeThreadEvent(event: ThreadEvent): string {
  switch (event.type) {
    case "thread.started":
      return "[codex] thread.started";
    case "turn.started":
      return "[codex] turn.started";
    case "turn.completed":
      return "[codex] turn.completed";
    case "turn.failed":
      return `[codex] turn.failed: ${event.error.message}`;
    case "item.started":
      return `[codex] item.started:${describeThreadItem(event.item)}`;
    case "item.updated":
      return `[codex] item.updated:${describeThreadItem(event.item)}`;
    case "item.completed":
      return `[codex] item.completed:${describeThreadItem(event.item)}`;
    case "error":
      return `[codex] error: ${event.message}`;
    default:
      return `[codex] unknown-event: ${JSON.stringify(event)}`;
  }
}

interface ScreenshotAnalysisOptions {
  apiKey: string;
  workspaceDir: string;
  prompt: string;
  logEvent: LogFn;
}

function resolveCodexPath(): string | null {
  const candidates = [
    process.env.CODEX_PATH_OVERRIDE?.trim() ?? null,
    "/root/.bun/bin/codex",
    "/usr/local/bin/codex",
    "/usr/bin/codex",
  ];

  for (const candidate of candidates) {
    if (!candidate) {
      continue;
    }
    if (existsSync(candidate)) {
      return candidate;
    }
  }
  return null;
}

export async function runScreenshotAnalysis({
  apiKey,
  workspaceDir,
  prompt,
  logEvent,
}: ScreenshotAnalysisOptions): Promise<ScreenshotAnalysis> {
  const codexHomeEnv = process.env.CODEX_HOME?.trim();
  const defaultHome = process.env.HOME?.trim();
  const osHome = homedir()?.trim();
  const resolvedHome =
    defaultHome && defaultHome.length > 0
      ? defaultHome
      : osHome && osHome.length > 0
        ? osHome
        : "/root";
  const codexHome =
    codexHomeEnv && codexHomeEnv.length > 0
      ? codexHomeEnv
      : join(resolvedHome, ".codex");
  if (!existsSync(codexHome)) {
    mkdirSync(codexHome, { recursive: true });
  }
  const codexConfigDir = join(codexHome, "config");
  if (!existsSync(codexConfigDir)) {
    mkdirSync(codexConfigDir, { recursive: true });
  }
  const codexConfigFile = join(codexConfigDir, "config.toml");
  if (!existsSync(codexConfigFile)) {
    writeFileSync(codexConfigFile, "", { encoding: "utf8" });
  }
  const codexAuthPath = join(codexHome, "auth.json");
  let existingAuthKey: string | null = null;
  if (existsSync(codexAuthPath)) {
    try {
      const parsed = JSON.parse(readFileSync(codexAuthPath, "utf8"));
      const keyCandidate =
        typeof parsed.OPENAI_API_KEY === "string"
          ? parsed.OPENAI_API_KEY.trim()
          : null;
      if (keyCandidate && keyCandidate.length > 0) {
        existingAuthKey = keyCandidate;
      }
    } catch {
      existingAuthKey = null;
    }
  }
  const xdgConfigDir = join(resolvedHome, ".config");
  const xdgCodexDir = join(xdgConfigDir, "codex");
  if (!existsSync(xdgCodexDir)) {
    mkdirSync(xdgCodexDir, { recursive: true });
  }
  const xdgConfigFile = join(xdgCodexDir, "config.toml");
  if (!existsSync(xdgConfigFile)) {
    writeFileSync(xdgConfigFile, "", { encoding: "utf8" });
  }

  const codexEnv: NodeJS.ProcessEnv = {
    ...process.env,
    CODEX_HOME: codexHome,
    HOME: resolvedHome,
  };

  if (apiKey && apiKey !== existingAuthKey) {
    writeFileSync(
      codexAuthPath,
      JSON.stringify({ OPENAI_API_KEY: apiKey }, null, 2),
      { encoding: "utf8" }
    );
  }

  process.env.CODEX_HOME = codexEnv.CODEX_HOME;
  process.env.HOME = codexEnv.HOME;

  await logEvent(
    `Codex directories prepared: HOME=${codexEnv.HOME}, CODEX_HOME=${codexEnv.CODEX_HOME}, codexConfigDir=${codexConfigDir}, xdgCodexDir=${xdgCodexDir}`
  );
  await logEvent(
    `Codex env snapshot: ${JSON.stringify({
      HOME: codexEnv.HOME,
      CODEX_HOME: codexEnv.CODEX_HOME,
      PATH: codexEnv.PATH,
    })}`
  );

  await logEvent("Requesting Codex screenshot summary...");
  const codexPath = resolveCodexPath();
  if (!codexPath) {
    await logEvent("Codex binary not found");
    throw new Error("Codex binary not found");
  }

  await logEvent("Codex login skipped; auth.json ensured for CLI access");
  await logEvent(
    `Codex output schema: ${JSON.stringify(screenshotAnalysisJsonSchema)}`
  );

  const codex = new Codex({
    apiKey,
    codexPathOverride: codexPath ?? undefined,
  });
  const thread = codex.startThread({
    workingDirectory: workspaceDir,
    model: "gpt-5-codex",
  });
  const turn = await thread.runStreamed(prompt, {
    outputSchema: screenshotAnalysisJsonSchema,
  });

  let agentMessage = "";
  for await (const event of turn.events) {
    await logEvent(describeThreadEvent(event));
    if (event.type === "item.completed") {
      const itemType = resolveItemType(event.item);
      if (itemType === "agent_message" || itemType === "assistant_message") {
        const payload = event.item as Record<string, unknown>;
        const textValue = payload.text;
        if (typeof textValue === "string" && textValue.trim().length > 0) {
          agentMessage = textValue;
        } else if (payload.output_json !== undefined) {
          agentMessage = JSON.stringify(payload.output_json);
        }
      } else if (event.item && typeof event.item === "object") {
        const payload = event.item as Record<string, unknown>;
        if (
          payload.output_json !== undefined &&
          agentMessage.trim().length === 0
        ) {
          agentMessage = JSON.stringify(payload.output_json);
        }
        await logEvent(`[codex] item payload: ${JSON.stringify(event.item)}`);
      }
    }
  }

  const finalResponse = agentMessage.trim();
  if (finalResponse.length === 0) {
    await logEvent("Codex did not return a structured response.");
    throw new Error("Codex did not return a structured response.");
  }

  let parsedJson: unknown;
  try {
    parsedJson = JSON.parse(finalResponse);
  } catch (parseError) {
    const message =
      parseError instanceof Error
        ? parseError.message
        : String(parseError ?? "unknown parse error");
    await logEvent(`Codex response JSON parse failed: ${message}`);
    throw new Error(`Codex response JSON parse failed: ${message}`);
  }

  const parsed = screenshotAnalysisSchema.safeParse(parsedJson);
  if (!parsed.success) {
    await logEvent(`Codex response validation failed: ${parsed.error.message}`);
    throw new Error(
      `Codex response validation failed: ${parsed.error.message}`
    );
  }

  return parsed.data;
}
