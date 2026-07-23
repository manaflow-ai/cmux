extension CMUXCLI {
    static let piExtensionSourcePart2 = #"""
async function sendHook(
  dispatcher: PiCmuxCommandDispatcher,
  subcommand: string,
  context: PiExtensionContextSnapshot,
  extra: HookExtra = {},
): Promise<boolean> {
  if (process.env.CMUX_PI_HOOKS_DISABLED === "1") return true;
  const sessionId = context.sessionId;
  if (!sessionId) return true;
  const target = surfaceTargetArgs(dispatcher, sessionId);
  if (!target) return !firstString(process.env.CMUX_PANEL_ID);

  const cwd = context.cwd;
  const payload: HookExtra = {
    session_id: sessionId,
    cwd,
    hook_event_name: eventName(subcommand),
    event: eventName(subcommand),
    ...extra,
  };
  const result = await dispatcher.run(
    ["hooks", "pi", subcommand, ...target],
    cwd,
    JSON.stringify(payload),
    context,
  );
  if (result.ok) rememberSurfaceTarget(dispatcher, sessionId, result);
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

const resolvedSurfaceTargets = new WeakMap<PiCmuxCommandDispatcher, Map<string, string[]>>();

function surfaceTargetsFor(dispatcher: PiCmuxCommandDispatcher): Map<string, string[]> {
  let targets = resolvedSurfaceTargets.get(dispatcher);
  if (!targets) {
    targets = new Map();
    resolvedSurfaceTargets.set(dispatcher, targets);
  }
  return targets;
}

function surfaceTargetArgs(dispatcher: PiCmuxCommandDispatcher, sessionId: string): string[] | null {
  const resolved = surfaceTargetsFor(dispatcher).get(sessionId);
  if (resolved) return [...resolved];
  const surfaceId = firstString(process.env.CMUX_SURFACE_ID);
  if (!surfaceId) return null;
  const args: string[] = [];
  const workspaceId = firstString(process.env.CMUX_WORKSPACE_ID);
  if (workspaceId) args.push("--workspace", workspaceId);
  args.push("--surface", surfaceId);
  return args;
}

function rememberSurfaceTarget(
  dispatcher: PiCmuxCommandDispatcher,
  sessionId: string,
  result: CommandResult,
): void {
  const payload = parseJSONOutput(result);
  const workspaceId = firstString(payload?.workspace_id);
  const surfaceId = firstString(payload?.surface_id);
  if (!workspaceId || !surfaceId) return;
  surfaceTargetsFor(dispatcher).set(
    sessionId,
    ["--workspace", workspaceId, "--surface", surfaceId],
  );
}

function releaseSessionRuntime(
  dispatcher: PiCmuxCommandDispatcher,
  sessionStates: Map<string, SessionState>,
  sessionId: string,
): void {
  sessionStates.delete(sessionId);
  surfaceTargetsFor(dispatcher).delete(sessionId);
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

async function ensureResumeBinding(
  dispatcher: PiCmuxCommandDispatcher,
  context: PiExtensionContextSnapshot,
  sessionId: string,
): Promise<void> {
  if (process.env.CMUX_PI_HOOKS_DISABLED === "1") return;
  const target = surfaceTargetArgs(dispatcher, sessionId);
  if (!target) return;

  const cwd = context.cwd;
  const resumeArgv = sanitizedResumeArgv(sessionId);
  const set = await dispatcher.run([
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
  ], cwd, undefined, context);
  if (!set.ok && !set.surfaceUnavailable) {
    warn(context, "failed to set Pi resume binding", {
      status: set.status,
      stderr_available: set.stderr.trim().length > 0,
      error_available: set.error !== undefined,
    });
    return;
  }
  if (set.surfaceUnavailable) return;

  const verification = await dispatcher.run(
    ["--json", "surface", "resume", "get", ...target],
    cwd,
    undefined,
    context,
  );
  if (verification.surfaceUnavailable) return;
  const verified = parseJSONOutput(verification);
  if (!resumeBindingMatches(verified, sessionId)) {
    warn(context, "Pi resume binding did not verify after write", { session_id: sessionId });
  }
}

async function clearResumeBinding(
  dispatcher: PiCmuxCommandDispatcher,
  context: PiExtensionContextSnapshot,
  sessionId: string,
): Promise<void> {
  if (process.env.CMUX_PI_HOOKS_DISABLED === "1") return;
  const target = surfaceTargetArgs(dispatcher, sessionId);
  if (!target) return;
  const cwd = context.cwd;
  const result = await dispatcher.run([
    "--json",
    "surface",
    "resume",
    "clear",
    ...target,
    "--checkpoint-id",
    sessionId,
    "--source",
    "agent-hook",
  ], cwd, undefined, context);
  if (result.surfaceUnavailable) return;
  if (!result.ok) {
    warn(context, "failed to clear Pi resume binding", {
      status: result.status,
      stderr_available: result.stderr.trim().length > 0,
      error_available: result.error !== undefined,
    });
  }
}

function sendFeed(
  dispatcher: PiCmuxCommandDispatcher,
  sessionStates: Map<string, SessionState>,
  eventName: "PreToolUse" | "PostToolUse",
  context: PiExtensionContextSnapshot,
  event: unknown,
): void {
  if (process.env.CMUX_PI_HOOKS_DISABLED === "1") return;
  if (!dispatcher.canDispatch) return;
  const sessionId = context.sessionId;
  if (!sessionId) return;
  const target = surfaceTargetArgs(dispatcher, sessionId);
  if (!target) return;
  if (sessionStates.get(sessionId)?.stopped) return;
  const cwd = context.cwd;
  const toolCallId = firstString(objectValue(event, ["toolCallId", "tool_call_id", "id"]));
  const toolName = firstString(objectValue(event, ["toolName", "tool_name", "name"]));
  const projectionState: PiFeedProjectionState = { remainingNodes: 48, seen: new WeakSet() };
  const payload: HookExtra = {
    session_id: utf8Prefix(sessionId, 256),
    cwd: utf8Prefix(cwd, 2048),
    hook_event_name: eventName,
    event: eventName,
    turn_id: utf8Prefix(currentTurnId(sessionStates, sessionId, event), 256),
  };
  const boundedToolCallId = utf8Prefix(toolCallId, 256);
  if (boundedToolCallId !== undefined) payload.tool_call_id = boundedToolCallId;
  const boundedToolName = utf8Prefix(toolName, 256);
  if (boundedToolName !== undefined) payload.tool_name = boundedToolName;
  const toolInput = objectValue(event, ["args", "input"]);
  if (toolInput !== undefined) payload.tool_input = projectPiFeedValue(toolInput, projectionState);
  if (eventName === "PostToolUse") {
    const toolResult = objectValue(event, ["result", "details", "content"]);
    if (toolResult !== undefined) {
      payload.tool_result = projectPiFeedValue(toolResult, projectionState, 0, false);
    }
    const isError = objectValue(event, ["isError", "is_error"]);
    if (isError !== undefined) payload.is_error = projectPiFeedValue(isError, projectionState);
  }
  dispatcher.enqueueFeed(`${sessionId}:${toolCallId || toolName || "unknown"}`, {
    args: ["hooks", "feed", "--source", "pi", "--event", eventName, ...target],
    cwd,
    payload,
    context,
    terminal: eventName === "PostToolUse",
  });
}

async function publishPendingCompletion(
  dispatcher: PiCmuxCommandDispatcher,
  sessionStates: Map<string, SessionState>,
  context: PiExtensionContextSnapshot,
  sessionId: string,
): Promise<void> {
  const completion = settleTurn(sessionStates, sessionId);
  if (!completion) return;
  const feedDelivered = await dispatcher.finishFeedForSession(sessionId);
  if (!feedDelivered) {
    warn(context, "cmux terminal feed delivery failed", { session_id: sessionId });
  }
  const stopPayload: HookExtra = {
    last_assistant_message: completion.lastAssistantMessage,
    turn_id: completion.turnId,
  };
  if (feedDelivered) {
    const notificationRouted = await sendHook(dispatcher, "notification", context, {
      message: completion.lastAssistantMessage || "Task completed",
      turn_id: completion.turnId,
      notification: { type: completion.notificationType },
    });
    if (notificationRouted) stopPayload.cmux_notification_routed = true;
  }
  await sendHook(dispatcher, "stop", context, stopPayload);
}

export default function cmuxPiSessionExtension(pi: ExtensionAPI) {
  const dispatcher = new PiCmuxCommandDispatcher();
  const sessionStates = new Map<string, SessionState>();

  pi.on("session_start", async (_event, ctx) => {
    const context = snapshotContext(ctx);
    const sessionId = context.sessionId;
    if (sessionId) {
      const state = stateFor(sessionStates, sessionId);
      state.pendingCompletion = undefined;
      state.stopped = false;
    }
    const ok = await sendHook(dispatcher, "session-start", context);
    if (ok && sessionId) await ensureResumeBinding(dispatcher, context, sessionId);
  });

  pi.on("before_agent_start", async (event, ctx) => {
    const context = snapshotContext(ctx);
    const sessionId = context.sessionId;
    const turnId = sessionId ? beginTurn(sessionStates, sessionId, event) : undefined;
    await sendHook(dispatcher, "prompt-submit", context, { prompt: event.prompt, turn_id: turnId });
  });

  pi.on("tool_execution_start", async (event, ctx) => {
    const context = snapshotContext(ctx);
    sendFeed(dispatcher, sessionStates, "PreToolUse", context, event);
  });

  pi.on("tool_execution_end", async (event, ctx) => {
    const context = snapshotContext(ctx);
    sendFeed(dispatcher, sessionStates, "PostToolUse", context, event);
  });

  pi.on("agent_end", async (event, ctx) => {
    const context = snapshotContext(ctx);
    const sessionId = context.sessionId;
    if (!sessionId) return;
    const state = stateFor(sessionStates, sessionId);
    const message = lastAssistantMessage(event);
    // Preserve the latest low-level result until Pi confirms no automatic work remains.
    state.pendingCompletion = {
      lastAssistantMessage: message || state.pendingCompletion?.lastAssistantMessage,
      notificationType: firstString(objectValue(event, ["stopReason", "reason", "terminationReason"])) || "completed",
      turnId: currentTurnId(sessionStates, sessionId, event),
    };
    // Older Pi versions do not emit agent_settled, so retain their established completion behavior.
    if (!supportsAgentSettled()) {
      await publishPendingCompletion(dispatcher, sessionStates, context, sessionId);
    }
  });

  pi.on("agent_settled", async (_event, ctx) => {
    const context = snapshotContext(ctx);
    const isIdle = ctx.isIdle();
    const sessionId = context.sessionId;
    if (!sessionId || !isIdle) return;
    // Consume pending completion before subprocess calls so duplicate settlement cannot notify twice.
    await publishPendingCompletion(dispatcher, sessionStates, context, sessionId);
  });

  pi.on("session_shutdown", async (event, ctx) => {
    const context = snapshotContext(ctx);
    const sessionId = context.sessionId;
    if (!sessionId) return;
    const state = stateFor(sessionStates, sessionId);
    let stopPayload: HookExtra | undefined;
    if (!state.stopped) {
      const turnId = finishTurn(sessionStates, sessionId, event);
      stopPayload = {
        turn_id: turnId,
        terminationReason: firstString(objectValue(event, ["reason"])) || "session_shutdown",
      };
    }
    const feedDelivered = await dispatcher.finishFeedForSession(sessionId);
    if (!feedDelivered) warn(context, "cmux terminal feed delivery failed", { session_id: sessionId });
    if (stopPayload) await sendHook(dispatcher, "stop", context, stopPayload);
    try {
      await clearResumeBinding(dispatcher, context, sessionId);
    } finally {
      releaseSessionRuntime(dispatcher, sessionStates, sessionId);
    }
  });
}
"""#
}
