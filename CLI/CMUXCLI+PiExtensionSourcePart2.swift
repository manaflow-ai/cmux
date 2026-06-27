extension CMUXCLI {
    static let piExtensionSourcePart2 = #"""
}

function sendHook(subcommand: string, ctx: ExtensionContext, extra: HookExtra = {}): boolean {
  if (process.env.CMUX_PI_HOOKS_DISABLED === "1") return true;
  if (!process.env.CMUX_SURFACE_ID) return true;

  const sessionId = sessionIdFrom(ctx);
  if (!sessionId) return true;

  const cwd = cwdFrom(ctx);
  const payload: HookExtra = {
    session_id: sessionId,
    cwd,
    hook_event_name: eventName(subcommand),
    event: eventName(subcommand),
    ...extra,
  };
  const result = runCmux(["hooks", "pi", subcommand], cwd, JSON.stringify(payload));
  if (!result.ok) {
    warn(ctx, "cmux hook command failed", {
      subcommand,
      status: result.status,
      stderr_available: result.stderr.trim().length > 0,
      error_available: result.error !== undefined,
    });
  }
  return result.ok;
}

function surfaceTargetArgs(): string[] | null {
  const surfaceId = firstString(process.env.CMUX_SURFACE_ID);
  if (!surfaceId) return null;
  const args: string[] = [];
  const workspaceId = firstString(process.env.CMUX_WORKSPACE_ID);
  if (workspaceId) args.push("--workspace", workspaceId);
  args.push("--surface", surfaceId);
  return args;
}

function parseJSONOutput(result: CommandResult): Record<string, unknown> | null {
  if (!result.ok) return null;
  try {
    const parsed = JSON.parse(result.stdout);
    return parsed && typeof parsed === "object" && !Array.isArray(parsed) ? parsed as Record<string, unknown> : null;
  } catch (_) {
    return null;
  }
}

function resumeBindingMatches(payload: Record<string, unknown> | null, sessionId: string): boolean {
  const binding = payload?.resume_binding;
  if (!binding || typeof binding !== "object") return false;
  const typed = binding as Record<string, unknown>;
  return firstString(typed.kind) === "pi" &&
    firstString(typed.checkpoint_id, typed.checkpointId) === sessionId;
}

const piOptionsWithValue = new Set([
  "--model",
  "-m",
  "--thinking",
  "--provider",
  "--extension",
  "-e",
  "--skill",
  "--mcp-config",
  "--permission-mode",
  "--session-dir",
  "--config",
  "--profile",
  "--system-prompt",
  "--append-system-prompt",
  "--cwd",
  "--dir",
  "--trust",
  "--sandbox",
]);

const piOptionsWithoutValue = new Set([
  "--no-color",
  "--dangerously-skip-permissions",
  "--yolo",
]);

const piSelectorsToDrop = new Set([
  "--session",
  "-s",
  "--resume",
  "--fork",
  "--api-key",
  "--prompt",
  "--print",
]);

function sanitizedResumeArgv(sessionId: string): string[] {
  const raw = normalizedLaunchArgv();
  const executable = raw[0] || resolveExecutable("pi");
  const out = [executable, "--session", sessionId];
  for (let index = 1; index < raw.length; index += 1) {
    const arg = raw[index];
    if (!arg) continue;
    if (piSelectorsToDrop.has(arg)) {
      if (index + 1 < raw.length && !raw[index + 1].startsWith("-")) index += 1;
      continue;
    }
    if (
      arg.startsWith("--session=") ||
      arg.startsWith("--resume=") ||
      arg.startsWith("--fork=") ||
      arg.startsWith("--api-key=") ||
      arg.startsWith("--prompt=")
    ) {
      continue;
    }
    if (piOptionsWithValue.has(arg)) {
      out.push(arg);
      if (index + 1 < raw.length) {
        out.push(raw[index + 1]);
        index += 1;
      }
      continue;
    }
    if ([...piOptionsWithValue].some((option) => arg.startsWith(`${option}=`)) || piOptionsWithoutValue.has(arg)) {
      out.push(arg);
    }
  }
  return out;
}

function ensureResumeBinding(ctx: ExtensionContext, sessionId: string, cwd: string): void {
  if (process.env.CMUX_PI_HOOKS_DISABLED === "1") return;
  const target = surfaceTargetArgs();
  if (!target) return;

  const resumeArgv = sanitizedResumeArgv(sessionId);
  const set = runCmux([
    "--json",
    "surface",
    "resume",
    "set",
    ...target,
    "--name",
    "Pi",
    "--kind",
    "pi",
    "--checkpoint-id",
    sessionId,
    "--source",
    "agent-hook",
    "--cwd",
    cwd,
    "--",
    ...resumeArgv,
  ], cwd);
  if (!set.ok) {
    warn(ctx, "failed to set Pi resume binding", {
      status: set.status,
      stderr_available: set.stderr.trim().length > 0,
      error_available: set.error !== undefined,
    });
    return;
  }

  const verified = parseJSONOutput(runCmux(["--json", "surface", "resume", "get", ...target], cwd));
  if (!resumeBindingMatches(verified, sessionId)) {
    warn(ctx, "Pi resume binding did not verify after write", { session_id: sessionId });
  }
}

function clearResumeBinding(ctx: ExtensionContext, sessionId: string, cwd: string): boolean {
  if (process.env.CMUX_PI_HOOKS_DISABLED === "1") return true;
  const target = surfaceTargetArgs();
  if (!target) return true;
  const result = runCmux([
    "--json",
    "surface",
    "resume",
    "clear",
    ...target,
    "--checkpoint-id",
    sessionId,
    "--source",
    "agent-hook",
  ], cwd);
  if (!result.ok) {
    warn(ctx, "failed to clear Pi resume binding", {
      status: result.status,
      stderr_available: result.stderr.trim().length > 0,
      error_available: result.error !== undefined,
    });
  }
  return result.ok;
}

function sendFeed(eventName: "PreToolUse" | "PostToolUse", ctx: ExtensionContext, event: unknown, extra: HookExtra = {}): void {
  if (process.env.CMUX_PI_HOOKS_DISABLED === "1") return;
  if (!process.env.CMUX_SURFACE_ID) return;
  const sessionId = sessionIdFrom(ctx);
  if (!sessionId) return;
  const cwd = cwdFrom(ctx);
  const payload: HookExtra = {
    session_id: sessionId,
    cwd,
    hook_event_name: eventName,
    event: eventName,
    turn_id: currentTurnId(sessionId, event),
    tool_call_id: firstString(objectValue(event, ["toolCallId", "tool_call_id", "id"])),
    tool_name: firstString(objectValue(event, ["toolName", "tool_name", "name"])),
    tool_input: objectValue(event, ["args", "input"]),
    ...extra,
  };
  try {
    const child = spawn(cmuxExecutable(), ["hooks", "feed", "--source", "pi", "--event", eventName], {
      env: hookEnvironment(cwd, true),
      stdio: ["pipe", "ignore", "ignore"],
      detached: true,
    });
    child.on("error", () => {});
    child.stdin.on("error", () => {});
    child.stdin.end(JSON.stringify(payload));
    child.unref();
  } catch (_) {}
}

export default function cmuxPiSessionExtension(pi: ExtensionAPI) {
  pi.on("session_start", async (_event, ctx) => {
    const sessionId = sessionIdFrom(ctx);
    const cwd = cwdFrom(ctx);
    if (sessionId) stateFor(sessionId).stopped = false;
    const ok = sendHook("session-start", ctx);
    if (ok && sessionId) ensureResumeBinding(ctx, sessionId, cwd);
  });

  pi.on("before_agent_start", async (event, ctx) => {
    const sessionId = sessionIdFrom(ctx);
    const turnId = sessionId ? beginTurn(sessionId, event) : undefined;
    sendHook("prompt-submit", ctx, { prompt: event.prompt, turn_id: turnId });
  });

  pi.on("tool_execution_start", async (event, ctx) => {
    sendFeed("PreToolUse", ctx, event);
  });

  pi.on("tool_execution_end", async (event, ctx) => {
    sendFeed("PostToolUse", ctx, event, {
      tool_result: objectValue(event, ["result", "details", "content"]),
      is_error: objectValue(event, ["isError", "is_error"]),
    });
  });

  pi.on("agent_end", async (event, ctx) => {
    const sessionId = sessionIdFrom(ctx);
    const turnId = sessionId ? finishTurn(sessionId, event) : undefined;
    const message = lastAssistantMessage(event);
    sendHook("stop", ctx, {
      last_assistant_message: message,
      turn_id: turnId,
      cmux_notification_routed: true,
    });
    sendHook("notification", ctx, {
      message: message || "Task completed",
      turn_id: turnId,
      notification: {
        type: firstString(objectValue(event, ["stopReason", "reason", "terminationReason"])) || "completed",
      },
    });
  });

  pi.on("session_shutdown", async (event, ctx) => {
    const sessionId = sessionIdFrom(ctx);
    if (!sessionId) return;
    const state = stateFor(sessionId);
    const cwd = cwdFrom(ctx);
    if (!state.stopped) {
      const turnId = finishTurn(sessionId, event);
      sendHook("stop", ctx, {
        turn_id: turnId,
        terminationReason: firstString(objectValue(event, ["reason"])) || "session_shutdown",
      });
    }
    if (clearResumeBinding(ctx, sessionId, cwd)) sessionStates.delete(sessionId);
  });
}
"""#
}
