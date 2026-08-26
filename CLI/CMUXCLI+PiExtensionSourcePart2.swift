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
  dispatcher.releaseSession(sessionId);
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
  if (!set.ok && !set.surfaceUnavailable) return;
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
    await warn(context, "Pi resume binding did not verify after write", {
      session_id: sessionId,
      hook_name: "surface-resume-get",
      reason: "verification-failure",
    });
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
  await dispatcher.run([
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
}

type PiFeedEventName =
  | "PreToolUse"
  | "PostToolUse"
  | "PreCompact"
  | "PostCompact"
  | "SubagentStart"
  | "SubagentStop";

const subagentToolNames = new Set([
  "subagent",
  "team_spawn",
  "superpowers_dispatch",
  "Task",
]);

function isSubagentTool(event: unknown): boolean {
  const toolName = firstString(objectValue(event, ["toolName", "tool_name", "name"]));
  return toolName !== null && (subagentToolNames.has(toolName) || /subagent/i.test(toolName));
}

function isTerminalFeedEvent(eventName: PiFeedEventName): boolean {
  return eventName === "PostToolUse" || eventName === "SubagentStop";
}

function prepareFeedDispatch(
  dispatcher: PiCmuxCommandDispatcher,
  sessionStates: Map<string, SessionState>,
  eventName: PiFeedEventName,
  context: PiExtensionContextSnapshot,
  event: unknown,
): (() => void) | undefined {
  if (process.env.CMUX_PI_HOOKS_DISABLED === "1") return undefined;
  const sessionId = context.sessionId;
  if (!sessionId) return undefined;
  if (!dispatcher.canDispatch(sessionId)) return undefined;
  const state = stateFor(sessionStates, sessionId);
  if (state.stopped) return undefined;
  const cwd = context.cwd;
  const toolCallId = firstString(objectValue(event, ["toolCallId", "tool_call_id", "id"]));
  const toolName = firstString(objectValue(event, ["toolName", "tool_name", "name"]));
  const turnId = currentTurnId(sessionStates, sessionId, event);
  const toolInput = objectValue(event, ["args", "input"]);
  const terminal = isTerminalFeedEvent(eventName);
  const toolResult = terminal
    ? objectValue(event, ["result", "details", "content"])
    : undefined;
  const isError = terminal ? objectValue(event, ["isError", "is_error"]) : undefined;
  return () => {
    const target = surfaceTargetArgs(dispatcher, sessionId);
    if (!target) return;

    // Pi invokes tool lifecycle handlers on its UI event loop. Keep those
    // callbacks lightweight by traversing and bounding tool payloads only in
    // the already-detached lifecycle task.
    const projectionState: PiFeedProjectionState = { remainingNodes: 48, seen: new WeakSet() };
    const payload: HookExtra = {
      session_id: utf8Prefix(sessionId, 256),
      cwd: utf8Prefix(cwd, 2048),
      hook_event_name: eventName,
      event: eventName,
      turn_id: utf8Prefix(turnId, 256),
    };
    const boundedToolCallId = utf8Prefix(toolCallId, 256);
    if (boundedToolCallId !== undefined) payload.tool_call_id = boundedToolCallId;
    const boundedToolName = utf8Prefix(toolName, 256);
    if (boundedToolName !== undefined) payload.tool_name = boundedToolName;
    if (toolInput !== undefined) payload.tool_input = projectPiFeedValue(toolInput, projectionState);
    if (toolResult !== undefined) {
      payload.tool_result = projectPiFeedValue(toolResult, projectionState, 0, false);
    }
    if (isError !== undefined) payload.is_error = projectPiFeedValue(isError, projectionState);
    dispatcher.enqueueFeed(`${sessionId}:${toolCallId || toolName || "unknown"}`, {
      args: ["hooks", "feed", "--source", "pi", "--event", eventName, ...target],
      cwd,
      payload,
      context,
      terminal,
      onFailure: () => { state.feedDeliveryFailed = true; },
    });
  };
}

async function warnFeedDeliveryDropped(
  context: PiExtensionContextSnapshot,
  sessionId: string,
): Promise<void> {
  await warn(context, "cmux feed delivery dropped", {
    session_id: sessionId,
    hook_name: "feed",
    reason: "dispatch-dropped",
  });
}

async function publishPendingCompletion(
  dispatcher: PiCmuxCommandDispatcher,
  sessionStates: Map<string, SessionState>,
  context: PiExtensionContextSnapshot,
  sessionId: string,
  completion: PendingCompletion,
): Promise<void> {
  await dispatcher.finishFeedForSession(sessionId);
  const state = stateFor(sessionStates, sessionId);
  const feedDelivered = !state.feedDeliveryFailed;
  state.feedDeliveryFailed = false;
  if (!feedDelivered) await warnFeedDeliveryDropped(context, sessionId);
  const stopPayload: HookExtra = {
    last_assistant_message: completion.lastAssistantMessage,
    turn_id: completion.turnId,
  };
  if (completion.suppressNotification) {
    // Stop normally creates cmux's native fallback notification when no explicit
    // notification was routed. Mark intentional interruption as already handled.
    stopPayload.cmux_notification_routed = true;
  } else if (feedDelivered) {
    const notificationRouted = await sendHook(dispatcher, "notification", context, {
      message: completion.lastAssistantMessage || "Task completed",
      turn_id: completion.turnId,
      notification: { type: completion.notificationType },
    });
    if (notificationRouted) stopPayload.cmux_notification_routed = true;
  }
  await sendHook(dispatcher, "stop", context, stopPayload);
}

// A stalled lifecycle hook may run for its full configured timeout while Pi
// keeps emitting tool events. Bound the pending tasks a session can stack
// behind it so bursts cannot pin unbounded event payloads: droppable Feed
// preparation is shed first and surfaces as a dropped delivery at completion.
const maximumPiLifecycleBacklogTasks = 32;

interface PiLifecycleQueue {
  enqueue(
    sessionId: string,
    context: PiExtensionContextSnapshot,
    operation: () => Promise<unknown> | unknown,
  ): Promise<void>;
  tryEnqueue(
    sessionId: string,
    context: PiExtensionContextSnapshot,
    operation: () => Promise<unknown> | unknown,
  ): boolean;
}

function createPiLifecycleQueue(): PiLifecycleQueue {
  const tails = new Map<string, Promise<void>>();
  const pendingCounts = new Map<string, number>();
  const enqueue = (
    sessionId: string,
    context: PiExtensionContextSnapshot,
    operation: () => Promise<unknown> | unknown,
  ): Promise<void> => {
    pendingCounts.set(sessionId, (pendingCounts.get(sessionId) || 0) + 1);
    const previous = tails.get(sessionId) || Promise.resolve();
    let tracked: Promise<void>;
    tracked = previous
      .then(operation)
      .then(() => undefined)
      .catch((error) => {
        const errorMessage = error instanceof Error ? error.message : undefined;
        return warn(context, "cmux lifecycle task failed", {
          hook_name: "lifecycle-task",
          reason: "extension-error",
          error_available: error !== undefined,
          error_message: utf8Prefix(errorMessage, 512),
        });
      })
      .finally(() => {
        const remaining = (pendingCounts.get(sessionId) || 1) - 1;
        if (remaining > 0) pendingCounts.set(sessionId, remaining);
        else pendingCounts.delete(sessionId);
        if (tails.get(sessionId) === tracked) tails.delete(sessionId);
      });
    tails.set(sessionId, tracked);
    return tracked;
  };
  return {
    enqueue,
    tryEnqueue(sessionId, context, operation) {
      if ((pendingCounts.get(sessionId) || 0) >= maximumPiLifecycleBacklogTasks) return false;
      void enqueue(sessionId, context, operation);
      return true;
    },
  };
}

export default function cmuxPiSessionExtension(pi: ExtensionAPI) {
  const dispatcher = new PiCmuxCommandDispatcher();
  const sessionStates = new Map<string, SessionState>();
  const lifecycleTasks = createPiLifecycleQueue();

  const enqueueLifecycleTask = (
    sessionId: string,
    context: PiExtensionContextSnapshot,
    operation: () => Promise<unknown> | unknown,
  ): Promise<void> => lifecycleTasks.enqueue(sessionId, context, operation);

  pi.on("session_start", (_event, ctx) => {
    const context = snapshotContext(ctx);
    const sessionId = context.sessionId;
    if (sessionId) {
      const state = stateFor(sessionStates, sessionId);
      state.pendingCompletion = undefined;
      state.feedDeliveryFailed = false;
      state.stopped = false;
    }
    if (!sessionId) return;
    enqueueLifecycleTask(sessionId, context, async () => {
      const ok = await sendHook(dispatcher, "session-start", context);
      if (ok) await ensureResumeBinding(dispatcher, context, sessionId);
    });
  });

  pi.on("before_agent_start", (event, ctx) => {
    const context = snapshotContext(ctx);
    const sessionId = context.sessionId;
    if (!sessionId) return;
    const turnId = beginTurn(sessionStates, sessionId, event);
    enqueueLifecycleTask(sessionId, context, () => (
      sendHook(dispatcher, "prompt-submit", context, { prompt: event.prompt, turn_id: turnId })
    ));
  });

  const enqueueFeed = (
    eventName: PiFeedEventName,
    event: unknown,
    ctx: ExtensionContext,
  ): void => {
    const context = snapshotContext(ctx);
    const sessionId = context.sessionId;
    if (!sessionId) return;
    const dispatch = prepareFeedDispatch(dispatcher, sessionStates, eventName, context, event);
    if (!dispatch) return;
    if (!lifecycleTasks.tryEnqueue(sessionId, context, dispatch)) {
      // A shed completion must fail visibly instead of reporting delivery.
      if (isTerminalFeedEvent(eventName)) stateFor(sessionStates, sessionId).feedDeliveryFailed = true;
    }
  };

  pi.on("tool_execution_start", (event, ctx) => {
    enqueueFeed(isSubagentTool(event) ? "SubagentStart" : "PreToolUse", event, ctx);
  });

  pi.on("tool_execution_end", (event, ctx) => {
    enqueueFeed(isSubagentTool(event) ? "SubagentStop" : "PostToolUse", event, ctx);
  });

  pi.on("session_before_compact", (event, ctx) => {
    enqueueFeed("PreCompact", event, ctx);
  });

  pi.on("session_compact", (event, ctx) => {
    enqueueFeed("PostCompact", event, ctx);
  });

  pi.on("agent_end", (event, ctx) => {
    const context = snapshotContext(ctx);
    const sessionId = context.sessionId;
    if (!sessionId) return;
    const state = stateFor(sessionStates, sessionId);
    const assistantCompletion = assistantCompletionFrom(event);
    // Preserve the latest low-level result until Pi confirms no automatic work remains.
    state.pendingCompletion = {
      lastAssistantMessage: assistantCompletion.lastAssistantMessage || state.pendingCompletion?.lastAssistantMessage,
      notificationType: firstString(objectValue(event, ["stopReason", "reason", "terminationReason"])) || "completed",
      turnId: currentTurnId(sessionStates, sessionId, event),
      suppressNotification: assistantCompletion.suppressNotification,
    };
    // Older Pi versions do not emit agent_settled, so retain their established completion behavior.
    if (!supportsAgentSettled()) {
      const completion = settleTurn(sessionStates, sessionId);
      if (completion) {
        enqueueLifecycleTask(sessionId, context, () => (
          publishPendingCompletion(dispatcher, sessionStates, context, sessionId, completion)
        ));
      }
    }
  });

  pi.on("agent_settled", (_event, ctx) => {
    const context = snapshotContext(ctx);
    const isIdle = ctx.isIdle();
    const sessionId = context.sessionId;
    if (!sessionId || !isIdle) return;
    // Consume pending completion before subprocess calls so duplicate settlement cannot notify twice.
    const completion = settleTurn(sessionStates, sessionId);
    if (completion) {
      enqueueLifecycleTask(sessionId, context, () => (
        publishPendingCompletion(dispatcher, sessionStates, context, sessionId, completion)
      ));
    }
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
    await enqueueLifecycleTask(sessionId, context, async () => {
      await dispatcher.finishFeedForSession(sessionId);
      const feedDelivered = !state.feedDeliveryFailed;
      state.feedDeliveryFailed = false;
      if (!feedDelivered) await warnFeedDeliveryDropped(context, sessionId);
      if (stopPayload) await sendHook(dispatcher, "stop", context, stopPayload);
      try {
        await clearResumeBinding(dispatcher, context, sessionId);
      } finally {
        releaseSessionRuntime(dispatcher, sessionStates, sessionId);
      }
    });
  });
}
"""#
}
