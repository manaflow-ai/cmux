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

function sendPromptHookAsync(ctx: ExtensionContext, extra: HookExtra): Promise<boolean> {
  if (process.env.CMUX_PI_HOOKS_DISABLED === "1") return Promise.resolve(true);
  if (!process.env.CMUX_SURFACE_ID) return Promise.resolve(true);

  const sessionId = sessionIdFrom(ctx);
  if (!sessionId) return Promise.resolve(true);

  const cwd = cwdFrom(ctx);
  const payload: HookExtra = {
    session_id: sessionId,
    cwd,
    hook_event_name: eventName("prompt-submit"),
    event: eventName("prompt-submit"),
    ...extra,
  };

  // Start the turn without waiting for a slow cmux hook process.
  return new Promise((resolve) => {
    let settled = false;
    let timeout: NodeJS.Timeout | undefined;
    const finish = (ok: boolean, status: number | null, error?: unknown) => {
      if (settled) return;
      settled = true;
      if (timeout) clearTimeout(timeout);
      if (!ok) {
        warn(ctx, "cmux hook command failed", {
          subcommand: "prompt-submit",
          status,
          stderr_available: false,
          error_available: error !== undefined,
        });
      }
      resolve(ok);
    };

    try {
      const child = spawn(cmuxExecutable(), ["hooks", "pi", "prompt-submit"], {
        env: hookEnvironment(cwd, true),
        stdio: ["pipe", "ignore", "ignore"],
        detached: true,
      });
      const killChildTree = () => {
        // A detached process group lets timeout cleanup include hook descendants.
        if (process.platform !== "win32" && child.pid) {
          try {
            process.kill(-child.pid, "SIGKILL");
            return;
          } catch (_) {}
        }
        child.kill("SIGKILL");
      };
      child.on("error", (error) => finish(false, null, error));
      child.on("close", (status) => finish(status === 0, status));
      child.stdin.on("error", (error) => {
        killChildTree();
        child.stdin.destroy();
        finish(false, null, error);
      });
      child.stdin.end(JSON.stringify(payload));
      // Bound the background hook without holding the Pi lifecycle callback.
      timeout = setTimeout(() => {
        killChildTree();
        child.stdin.destroy();
        finish(false, null, new Error("cmux hook command timed out"));
      }, 15000);
    } catch (error) {
      finish(false, null, error);
    }
  });
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
  const deliver = () => {
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
  };
  // Feed telemetry follows the prompt hook that establishes the active turn.
  const queue = promptHookQueues.get(sessionId);
  if (queue?.closed) return;
  const prompt = queue?.current;
  if (prompt) {
    void prompt.pending.then(() => {
      if (!prompt.discarded) deliver();
    });
  } else {
    deliver();
  }
}

function publishPendingCompletion(ctx: ExtensionContext, sessionId: string): void {
  const queue = promptHookQueues.get(sessionId);
  if (queue?.closed) return;
  const completion = settleTurn(sessionId);
  if (!completion) return;
  const prompt = queue?.current;
  const publish = () => {
    if (prompt?.discarded) {
      const state = sessionStates.get(sessionId);
      if (state?.stopped && !state.activeTurnId) {
        // Let shutdown publish the terminal stop for the discarded turn.
        state.activeTurnId = completion.turnId;
        state.stopped = false;
      }
      return;
    }
    const notificationRouted = sendHook("notification", ctx, {
      message: completion.lastAssistantMessage || "Task completed",
      turn_id: completion.turnId,
      notification: { type: completion.notificationType },
    });
    const stopPayload: HookExtra = {
      last_assistant_message: completion.lastAssistantMessage,
      turn_id: completion.turnId,
    };
    if (notificationRouted) stopPayload.cmux_notification_routed = true;
    sendHook("stop", ctx, stopPayload);
  };
  // Completion follows the prompt hook that establishes the active turn.
  if (prompt) void prompt.pending.then(publish);
  else publish();
}

export default function cmuxPiSessionExtension(pi: ExtensionAPI) {
  pi.on("session_start", async (_event, ctx) => {
    const sessionId = sessionIdFrom(ctx);
    const cwd = cwdFrom(ctx);
    if (sessionId) {
      // Start each session with a new hook queue generation.
      promptHookQueues.delete(sessionId);
      const state = stateFor(sessionId);
      state.pendingCompletion = undefined;
      state.stopped = false;
    }
    const ok = sendHook("session-start", ctx);
    if (ok && sessionId) ensureResumeBinding(ctx, sessionId, cwd);
  });

  pi.on("before_agent_start", async (event, ctx) => {
    const sessionId = sessionIdFrom(ctx);
    if (!sessionId) return;
    const existingQueue = promptHookQueues.get(sessionId);
    if (existingQueue?.closed) return;
    const queue = existingQueue ?? { closed: false, tail: Promise.resolve(true) };
    if (!existingQueue) promptHookQueues.set(sessionId, queue);
    const turnId = beginTurn(sessionId, event);
    const prompt: PromptHookEntry = { discarded: false, pending: Promise.resolve(true) };
    // Keep prompt hooks ordered without holding Pi's lifecycle callback.
    const pending = queue.tail.then(() => {
      if (queue.closed) {
        prompt.discarded = true;
        return true;
      }
      return sendPromptHookAsync(ctx, { prompt: event.prompt, turn_id: turnId });
    });
    prompt.pending = pending;
    queue.current = prompt;
    queue.tail = pending;
    void pending.finally(() => {
      if (!queue.closed && promptHookQueues.get(sessionId) === queue && queue.tail === pending) {
        promptHookQueues.delete(sessionId);
      }
    });
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
    if (!supportsAgentSettled()) publishPendingCompletion(ctx, sessionId);
  });

  pi.on("agent_settled", async (_event, ctx) => {
    const sessionId = sessionIdFrom(ctx);
    if (!sessionId || !ctx.isIdle()) return;
    // Consume pending completion before subprocess calls so duplicate settlement cannot notify twice.
    publishPendingCompletion(ctx, sessionId);
  });

  pi.on("session_shutdown", async (event, ctx) => {
    const sessionId = sessionIdFrom(ctx);
    if (!sessionId) return;
    const queue = promptHookQueues.get(sessionId);
    if (queue) {
      // Finish the active hook and discard hooks that have not started.
      queue.closed = true;
      await queue.tail;
    }
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
