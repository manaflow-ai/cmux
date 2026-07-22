extension CMUXCLI {
    static let piExtensionSourcePart2 = #"""
async function sendHook(
  subcommand: string,
  context: PiExtensionContextSnapshot,
  extra: HookExtra = {},
): Promise<boolean> {
  if (process.env.CMUX_PI_HOOKS_DISABLED === "1") return true;
  if (!process.env.CMUX_SURFACE_ID) return true;

  const sessionId = context.sessionId;
  if (!sessionId) return true;

  const cwd = context.cwd;
  const payload: HookExtra = {
    session_id: sessionId,
    cwd,
    hook_event_name: eventName(subcommand),
    event: eventName(subcommand),
    ...extra,
  };
  const result = await runCmux(["hooks", "pi", subcommand], cwd, JSON.stringify(payload), context);
  if (!result.ok && !result.surfaceUnavailable) {
    warn(context, "cmux hook command failed", {
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

async function ensureResumeBinding(context: PiExtensionContextSnapshot, sessionId: string): Promise<void> {
  if (process.env.CMUX_PI_HOOKS_DISABLED === "1") return;
  const target = surfaceTargetArgs();
  if (!target) return;

  const cwd = context.cwd;
  const resumeArgv = sanitizedResumeArgv(sessionId);
  const set = await runCmux([
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
  ], cwd, undefined, context, "explicit-surface");
  if (!set.ok && !set.surfaceUnavailable) {
    warn(context, "failed to set Pi resume binding", {
      status: set.status,
      stderr_available: set.stderr.trim().length > 0,
      error_available: set.error !== undefined,
    });
    return;
  }
  if (set.surfaceUnavailable) return;

  const verification = await runCmux(
    ["--json", "surface", "resume", "get", ...target],
    cwd,
    undefined,
    context,
    "explicit-surface",
  );
  if (verification.surfaceUnavailable) return;
  const verified = parseJSONOutput(verification);
  if (!resumeBindingMatches(verified, sessionId)) {
    warn(context, "Pi resume binding did not verify after write", { session_id: sessionId });
  }
}

async function clearResumeBinding(context: PiExtensionContextSnapshot, sessionId: string): Promise<boolean> {
  if (process.env.CMUX_PI_HOOKS_DISABLED === "1") return true;
  const target = surfaceTargetArgs();
  if (!target) return true;
  const cwd = context.cwd;
  const result = await runCmux([
    "--json",
    "surface",
    "resume",
    "clear",
    ...target,
    "--checkpoint-id",
    sessionId,
    "--source",
    "agent-hook",
  ], cwd, undefined, context, "explicit-surface");
  if (result.surfaceUnavailable) return true;
  if (!result.ok) {
    warn(context, "failed to clear Pi resume binding", {
      status: result.status,
      stderr_available: result.stderr.trim().length > 0,
      error_available: result.error !== undefined,
    });
  }
  return result.ok;
}

function sendFeed(
  eventName: "PreToolUse" | "PostToolUse",
  context: PiExtensionContextSnapshot,
  event: unknown,
  extra: HookExtra = {},
): void {
  if (process.env.CMUX_PI_HOOKS_DISABLED === "1") return;
  if (!process.env.CMUX_SURFACE_ID) return;
  if (!cmuxCommandDispatcher.canDispatch) return;
  const sessionId = context.sessionId;
  if (!sessionId) return;
  if (sessionStates.get(sessionId)?.stopped) return;
  const cwd = context.cwd;
  const toolCallId = firstString(objectValue(event, ["toolCallId", "tool_call_id", "id"]));
  const toolName = firstString(objectValue(event, ["toolName", "tool_name", "name"]));
  const payload: HookExtra = {
    session_id: sessionId,
    cwd,
    hook_event_name: eventName,
    event: eventName,
    turn_id: currentTurnId(sessionId, event),
    tool_call_id: toolCallId,
    tool_name: toolName,
    tool_input: objectValue(event, ["args", "input"]),
    ...extra,
  };
  enqueueCmuxFeed(`${sessionId}:${toolCallId || toolName || "unknown"}`, {
    args: ["hooks", "feed", "--source", "pi", "--event", eventName],
    cwd,
    input: JSON.stringify(payload),
    context,
    terminal: eventName === "PostToolUse",
  });
}

async function publishPendingCompletion(
  context: PiExtensionContextSnapshot,
  sessionId: string,
): Promise<void> {
  const completion = settleTurn(sessionId);
  if (!completion) return;
  await cmuxCommandDispatcher.finishFeedForSession(sessionId);
  const notificationRouted = await sendHook("notification", context, {
    message: completion.lastAssistantMessage || "Task completed",
    turn_id: completion.turnId,
    notification: { type: completion.notificationType },
  });
  const stopPayload: HookExtra = {
    last_assistant_message: completion.lastAssistantMessage,
    turn_id: completion.turnId,
  };
  if (notificationRouted) stopPayload.cmux_notification_routed = true;
  await sendHook("stop", context, stopPayload);
}

export default function cmuxPiSessionExtension(pi: ExtensionAPI) {
  pi.on("session_start", async (_event, ctx) => {
    const context = snapshotContext(ctx);
    const sessionId = context.sessionId;
    if (sessionId) {
      const state = stateFor(sessionId);
      state.pendingCompletion = undefined;
      state.stopped = false;
    }
    const ok = await sendHook("session-start", context);
    if (ok && sessionId) await ensureResumeBinding(context, sessionId);
  });

  pi.on("before_agent_start", async (event, ctx) => {
    const context = snapshotContext(ctx);
    const sessionId = context.sessionId;
    const turnId = sessionId ? beginTurn(sessionId, event) : undefined;
    await sendHook("prompt-submit", context, { prompt: event.prompt, turn_id: turnId });
  });

  pi.on("tool_execution_start", async (event, ctx) => {
    const context = snapshotContext(ctx);
    sendFeed("PreToolUse", context, event);
  });

  pi.on("tool_execution_end", async (event, ctx) => {
    const context = snapshotContext(ctx);
    sendFeed("PostToolUse", context, event, {
      tool_result: objectValue(event, ["result", "details", "content"]),
      is_error: objectValue(event, ["isError", "is_error"]),
    });
  });

  pi.on("agent_end", async (event, ctx) => {
    const context = snapshotContext(ctx);
    const sessionId = context.sessionId;
    if (!sessionId) return;
    const state = stateFor(sessionId);
    const message = lastAssistantMessage(event);
    // Preserve the latest low-level result until Pi confirms no automatic work remains.
    state.pendingCompletion = {
      lastAssistantMessage: message || state.pendingCompletion?.lastAssistantMessage,
      notificationType: firstString(objectValue(event, ["stopReason", "reason", "terminationReason"])) || "completed",
      turnId: currentTurnId(sessionId, event),
    };
    // Older Pi versions do not emit agent_settled, so retain their established completion behavior.
    if (!supportsAgentSettled()) await publishPendingCompletion(context, sessionId);
  });

  pi.on("agent_settled", async (_event, ctx) => {
    const context = snapshotContext(ctx);
    const isIdle = ctx.isIdle();
    const sessionId = context.sessionId;
    if (!sessionId || !isIdle) return;
    // Consume pending completion before subprocess calls so duplicate settlement cannot notify twice.
    await publishPendingCompletion(context, sessionId);
  });

  pi.on("session_shutdown", async (event, ctx) => {
    const context = snapshotContext(ctx);
    const sessionId = context.sessionId;
    if (!sessionId) return;
    const state = stateFor(sessionId);
    let stopPayload: HookExtra | undefined;
    if (!state.stopped) {
      const turnId = finishTurn(sessionId, event);
      stopPayload = {
        turn_id: turnId,
        terminationReason: firstString(objectValue(event, ["reason"])) || "session_shutdown",
      };
    }
    await cmuxCommandDispatcher.finishFeedForSession(sessionId);
    if (stopPayload) await sendHook("stop", context, stopPayload);
    if (await clearResumeBinding(context, sessionId)) sessionStates.delete(sessionId);
  });
}
"""#
}
