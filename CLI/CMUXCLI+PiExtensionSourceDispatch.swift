extension CMUXCLI {
    static let piExtensionSourceDispatch = #"""
type SurfaceDispatchState = "unknown" | "available" | "unavailable";
type PiCmuxCommandScope = "routable" | "explicit-surface";

interface PiFeedCommand {
  readonly args: string[];
  readonly cwd: string;
  readonly input: string;
  readonly context: PiExtensionContextSnapshot;
  readonly terminal: boolean;
}

interface PiCommandCancellation {
  cancelled: boolean;
  cancel?: () => void;
}

class PiCmuxCommandDispatcher {
  private static readonly maxPendingFeedCommands = 8;
  private static readonly maxCompactedTerminalSummaries = 64;
  private static readonly maxFeedInputBytes = 128 * 1024;
  private static readonly feedDrainDeadlineMs = 2500;
  private controlQueue: Promise<void> = Promise.resolve();
  private pendingFeedCommands = new Map<string, PiFeedCommand>();
  private priorityFeedCommands: PiFeedCommand[] = [];
  private feedDrainWaiters = new Map<string, Array<() => void>>();
  private routableState: SurfaceDispatchState = "unknown";
  private explicitSurfaceUnavailable = false;
  private didWarnSurfaceUnavailable = false;
  private feedRunning = false;
  private activeFeed: {
    sessionId: string | null;
    cancellation: PiCommandCancellation;
    command: PiFeedCommand;
  } | null = null;

  get canDispatch(): boolean {
    return this.routableState !== "unavailable";
  }

  run(
    args: string[],
    cwd: string,
    input: string | undefined,
    context: PiExtensionContextSnapshot,
    scope: PiCmuxCommandScope = "routable",
  ): Promise<CommandResult> {
    const scheduled = this.controlQueue.then(() => this.execute(args, cwd, input, context, undefined, scope));
    this.controlQueue = scheduled.then(() => undefined, () => undefined);
    return scheduled;
  }

  enqueueFeed(key: string, command: PiFeedCommand): void {
    if (!this.canDispatch) return;
    command = this.boundedFeedCommand(command);
    const sessionId = command.context.sessionId;

    const existing = this.pendingFeedCommands.get(key);
    if (existing) {
      // Once a completion is pending for a tool, never replace it with a late start event.
      if (existing.terminal && !command.terminal) return;
      // Reinsert coalesced entries so Map order continues to reflect event arrival order.
      this.pendingFeedCommands.delete(key);
      this.pendingFeedCommands.set(key, command);
    } else {
      if (this.queuedFeedCount(sessionId) >= PiCmuxCommandDispatcher.maxPendingFeedCommands) {
        if (!command.terminal) return;
        if (!this.evictPendingStartForCompletion(sessionId)) {
          this.compactPendingCompletion(command);
          return;
        }
      }
      this.pendingFeedCommands.set(key, command);
    }
    this.startNextFeed();
  }

  async finishFeedForSession(sessionId: string): Promise<void> {
    for (const [key, command] of this.pendingFeedCommands) {
      if (command.context.sessionId !== sessionId) continue;
      this.pendingFeedCommands.delete(key);
      if (command.terminal) this.priorityFeedCommands.push(command);
    }
    const active = this.activeFeed?.sessionId === sessionId ? this.activeFeed : null;
    if (active && !active.command.terminal) {
      active.cancellation.cancelled = true;
      active.cancellation.cancel?.();
    }
    this.startNextFeed();
    await this.waitForFeedDrainUntilDeadline(sessionId);
  }

  private queuedFeedCount(sessionId: string | null): number {
    let count = this.priorityFeedCommands.filter(
      (command) => command.context.sessionId === sessionId,
    ).length;
    for (const command of this.pendingFeedCommands.values()) {
      if (command.context.sessionId === sessionId) count += 1;
    }
    return count;
  }

  private waitForFeedDrain(sessionId: string): Promise<void> {
    if (!this.hasFeedWork(sessionId)) return Promise.resolve();
    return new Promise<void>((resolve) => {
      const waiters = this.feedDrainWaiters.get(sessionId) || [];
      waiters.push(resolve);
      this.feedDrainWaiters.set(sessionId, waiters);
    });
  }

  private waitForFeedDrainUntilDeadline(sessionId: string): Promise<void> {
    if (!this.hasFeedWork(sessionId)) return Promise.resolve();
    const drained = this.waitForFeedDrain(sessionId);
    return new Promise<void>((resolve) => {
      let settled = false;
      const finish = () => {
        if (settled) return;
        settled = true;
        clearTimeout(deadline);
        resolve();
      };
      const deadline = setTimeout(() => {
        this.discardFeedForSession(sessionId);
        finish();
      }, PiCmuxCommandDispatcher.feedDrainDeadlineMs);
      void drained.then(finish);
    });
  }

  private hasFeedWork(sessionId: string): boolean {
    if (this.activeFeed?.sessionId === sessionId) return true;
    if (this.priorityFeedCommands.some((command) => command.context.sessionId === sessionId)) return true;
    for (const command of this.pendingFeedCommands.values()) {
      if (command.context.sessionId === sessionId) return true;
    }
    return false;
  }

  private resolveDrainedFeedSessions(): void {
    for (const [sessionId, waiters] of this.feedDrainWaiters) {
      if (this.hasFeedWork(sessionId)) continue;
      this.feedDrainWaiters.delete(sessionId);
      for (const resolve of waiters) resolve();
    }
  }

  private evictPendingStartForCompletion(sessionId: string | null): boolean {
    for (const [key, command] of this.pendingFeedCommands) {
      if (!command.terminal && command.context.sessionId === sessionId) {
        this.pendingFeedCommands.delete(key);
        return true;
      }
    }
    return false;
  }

  private compactPendingCompletion(command: PiFeedCommand): void {
    const entries = Array.from(this.pendingFeedCommands.entries());
    for (let index = entries.length - 1; index >= 0; index -= 1) {
      const [key, pending] = entries[index];
      if (!pending.terminal) continue;
      if (pending.context.sessionId === command.context.sessionId) {
        this.pendingFeedCommands.set(key, this.compactedTerminalCommand(pending, command));
        return;
      }
    }
    for (let index = this.priorityFeedCommands.length - 1; index >= 0; index -= 1) {
      const pending = this.priorityFeedCommands[index];
      if (!pending.terminal) continue;
      if (pending.context.sessionId === command.context.sessionId) {
        this.priorityFeedCommands[index] = this.compactedTerminalCommand(pending, command);
        return;
      }
    }
  }

  private boundedFeedCommand(command: PiFeedCommand): PiFeedCommand {
    if (Buffer.byteLength(command.input, "utf8") <= PiCmuxCommandDispatcher.maxFeedInputBytes) {
      return command;
    }
    const payload = this.feedPayload(command);
    if (command.terminal) {
      const summary = this.terminalSummary(payload);
      delete payload.tool_input;
      delete payload.tool_result;
      payload.cmux_compacted_terminal_count = 1;
      payload.cmux_compacted_terminal_omitted_count = 0;
      payload.cmux_compacted_terminal_events = [summary];
    } else if (payload.tool_input !== undefined) {
      payload.tool_input = this.terminalResultSummary(payload.tool_input);
    }
    for (const key of ["session_id", "cwd", "turn_id", "tool_call_id", "tool_name"] as const) {
      if (typeof payload[key] === "string") payload[key] = payload[key].slice(0, 2048);
    }
    return { ...command, input: JSON.stringify(payload) };
  }

  private compactedTerminalCommand(existing: PiFeedCommand, incoming: PiFeedCommand): PiFeedCommand {
    const existingPayload = this.feedPayload(existing);
    const incomingPayload = this.feedPayload(incoming);
    const existingSummaries = Array.isArray(existingPayload.cmux_compacted_terminal_events)
      ? existingPayload.cmux_compacted_terminal_events
      : [this.terminalSummary(existingPayload)];
    const incomingSummaries = Array.isArray(incomingPayload.cmux_compacted_terminal_events)
      ? incomingPayload.cmux_compacted_terminal_events
      : [this.terminalSummary(incomingPayload)];
    const existingCount = this.compactedTerminalCount(existingPayload, existingSummaries.length);
    const incomingCount = this.compactedTerminalCount(incomingPayload, incomingSummaries.length);
    const combined = [...existingSummaries, ...incomingSummaries];
    const summaryLimit = PiCmuxCommandDispatcher.maxCompactedTerminalSummaries;
    let summaries = combined.length <= summaryLimit
      ? combined
      : [...combined.slice(0, summaryLimit / 2), ...combined.slice(-summaryLimit / 2)];
    const totalCount = existingCount + incomingCount;
    delete existingPayload.tool_input;
    delete existingPayload.tool_result;
    let input = "";
    while (true) {
      existingPayload.cmux_compacted_terminal_count = totalCount;
      existingPayload.cmux_compacted_terminal_omitted_count = Math.max(0, totalCount - summaries.length);
      existingPayload.cmux_compacted_terminal_events = summaries;
      input = JSON.stringify(existingPayload);
      if (Buffer.byteLength(input, "utf8") <= PiCmuxCommandDispatcher.maxFeedInputBytes || summaries.length <= 1) break;
      const keptCount = Math.max(1, Math.floor(summaries.length / 2));
      const leadingCount = Math.ceil(keptCount / 2);
      const trailingCount = keptCount - leadingCount;
      summaries = [
        ...summaries.slice(0, leadingCount),
        ...(trailingCount > 0 ? summaries.slice(-trailingCount) : []),
      ];
    }
    return { ...existing, input };
  }

  private compactedTerminalCount(payload: Record<string, unknown>, fallback: number): number {
    const count = payload.cmux_compacted_terminal_count;
    return typeof count === "number" && Number.isFinite(count) && count >= fallback ? count : fallback;
  }

  private feedPayload(command: PiFeedCommand): Record<string, unknown> {
    try {
      const payload: unknown = JSON.parse(command.input);
      if (payload && typeof payload === "object" && !Array.isArray(payload)) {
        return payload as Record<string, unknown>;
      }
    } catch (_) {}
    return {
      session_id: command.context.sessionId,
      cwd: command.cwd,
      hook_event_name: "PostToolUse",
      event: "PostToolUse",
    };
  }

  private terminalSummary(payload: Record<string, unknown>): Record<string, unknown> {
    const summary: Record<string, unknown> = {};
    for (const key of ["session_id", "turn_id", "tool_call_id", "tool_name"] as const) {
      const value = payload[key];
      if (typeof value === "string") summary[key] = value.slice(0, 256);
    }
    if (typeof payload.is_error === "boolean") summary.is_error = payload.is_error;
    if (payload.tool_result !== undefined) summary.tool_result = this.terminalResultSummary(payload.tool_result);
    return summary;
  }

  private terminalResultSummary(result: unknown): unknown {
    if (result === null) return { kind: "null" };
    if (typeof result === "string") return { kind: "text", length: result.length };
    if (typeof result === "boolean" || typeof result === "number") return { kind: typeof result };
    if (Array.isArray(result)) return { kind: "array", count: result.length };
    if (typeof result === "object") return { kind: "object", key_count: Object.keys(result).length };
    return { kind: typeof result };
  }

  private discardFeedForSession(sessionId: string): void {
    for (const [key, command] of this.pendingFeedCommands) {
      if (command.context.sessionId === sessionId) this.pendingFeedCommands.delete(key);
    }
    this.priorityFeedCommands = this.priorityFeedCommands.filter(
      (command) => command.context.sessionId !== sessionId,
    );
    const active = this.activeFeed?.sessionId === sessionId ? this.activeFeed : null;
    if (active) {
      active.cancellation.cancelled = true;
      active.cancellation.cancel?.();
    }
    this.resolveDrainedFeedSessions();
  }

  private startNextFeed(): void {
    if (this.feedRunning) return;
    if (!this.canDispatch) {
      this.pendingFeedCommands.clear();
      this.priorityFeedCommands = [];
      this.resolveDrainedFeedSessions();
      return;
    }
    let command = this.priorityFeedCommands.shift();
    if (!command) {
      const next = this.pendingFeedCommands.entries().next();
      if (next.done) return;
      const [key, pending] = next.value;
      this.pendingFeedCommands.delete(key);
      command = pending;
    }
    this.feedRunning = true;
    const cancellation: PiCommandCancellation = { cancelled: false };
    this.activeFeed = { sessionId: command.context.sessionId, cancellation, command };
    void this.execute(command.args, command.cwd, command.input, command.context, cancellation)
      .then((result) => {
        if (result.error instanceof Error && result.error.message.includes("timed out after")) {
          const sessionId = command.context.sessionId;
          if (sessionId) this.discardFeedForSession(sessionId);
        }
      })
      .catch(() => {})
      .finally(() => {
        if (this.activeFeed?.cancellation === cancellation) this.activeFeed = null;
        this.feedRunning = false;
        this.startNextFeed();
        this.resolveDrainedFeedSessions();
      });
  }

  private async execute(
    args: string[],
    cwd: string,
    input: string | undefined,
    context: PiExtensionContextSnapshot,
    cancellation?: PiCommandCancellation,
    scope: PiCmuxCommandScope = "routable",
  ): Promise<CommandResult> {
    if (scope === "routable" && this.routableState === "unavailable") {
      return this.surfaceUnavailableResult();
    }
    if (scope === "explicit-surface" && this.explicitSurfaceUnavailable) {
      return this.surfaceUnavailableResult();
    }

    const result = await this.spawnCmux(args, cwd, input, cancellation);
    if (this.isSurfaceResolutionFailure(result)) {
      if (scope === "explicit-surface") {
        this.explicitSurfaceUnavailable = true;
      } else {
        this.routableState = "unavailable";
        this.explicitSurfaceUnavailable = true;
      }
      if (!this.didWarnSurfaceUnavailable) {
        this.didWarnSurfaceUnavailable = true;
        warn(context, "cmux hook command failed", {
          status: result.status,
          stderr_available: result.stderr.trim().length > 0,
          error_available: result.error !== undefined,
          surface_unavailable: true,
          dispatch_disabled: true,
        });
      }
      return { ...result, surfaceUnavailable: true };
    }
    if (scope === "routable" && result.ok && this.routableState === "unknown") {
      this.routableState = "available";
    }
    return result;
  }

  private spawnCmux(
    args: string[],
    cwd: string,
    input?: string,
    cancellation?: PiCommandCancellation,
  ): Promise<CommandResult> {
    return new Promise<CommandResult>((resolve) => {
      let settled = false;
      let stdout = "";
      let stderr = "";
      let inputError: unknown;
      let timeout: ReturnType<typeof setTimeout> | null = null;
      let terminateGrace: ReturnType<typeof setTimeout> | null = null;
      let forceSettleTimeout: ReturnType<typeof setTimeout> | null = null;
      let terminationError: Error | undefined;

      const appendOutput = (current: string, chunk: unknown): string => {
        const limit = 1024 * 1024;
        if (current.length >= limit) return current;
        return current + String(chunk).slice(0, limit - current.length);
      };
      const settle = (result: CommandResult) => {
        if (settled) return;
        settled = true;
        if (timeout) clearTimeout(timeout);
        if (terminateGrace) clearTimeout(terminateGrace);
        if (forceSettleTimeout) clearTimeout(forceSettleTimeout);
        if (cancellation) cancellation.cancel = undefined;
        resolve(result);
      };
      const terminatedResult = (): CommandResult => ({
        ok: false,
        status: null,
        stdout,
        stderr,
        error: terminationError,
      });

      try {
        const child = spawn(cmuxExecutable(), args, {
          env: hookEnvironment(cwd, true),
          stdio: ["pipe", "pipe", "pipe"],
        });
        child.stdout.setEncoding("utf8");
        child.stderr.setEncoding("utf8");
        child.stdout.on("data", (chunk) => {
          stdout = appendOutput(stdout, chunk);
        });
        child.stderr.on("data", (chunk) => {
          stderr = appendOutput(stderr, chunk);
        });
        child.stdin.on("error", (error) => {
          inputError = error;
        });
        const beginTermination = (error: Error) => {
          if (terminationError) return;
          terminationError = error;
          child.stdin.destroy();
          try {
            child.kill("SIGTERM");
          } catch (_) {}
          terminateGrace = setTimeout(() => {
            try {
              child.kill("SIGKILL");
            } catch (_) {}
            forceSettleTimeout = setTimeout(() => {
              child.stdout.destroy();
              child.stderr.destroy();
              child.unref();
              settle(terminatedResult());
            }, 250);
          }, 250);
        };
        child.on("error", (error) => {
          settle(terminationError ? terminatedResult() : { ok: false, status: null, stdout, stderr, error });
        });
        child.on("close", (code) => {
          if (terminationError) {
            settle(terminatedResult());
            return;
          }
          const status = typeof code === "number" ? code : null;
          settle({
            ok: status === 0 && inputError === undefined,
            status,
            stdout,
            stderr,
            error: inputError,
          });
        });
        if (cancellation) {
          cancellation.cancel = () => beginTermination(new Error("cmux feed command cancelled"));
          if (cancellation.cancelled) cancellation.cancel();
        }
        timeout = setTimeout(() => {
          beginTermination(new Error("cmux command timed out after 5000ms"));
        }, 5000);
        child.stdin.end(input);
      } catch (error) {
        settle({ ok: false, status: null, stdout, stderr, error });
      }
    });
  }

  private isSurfaceResolutionFailure(result: CommandResult): boolean {
    if (result.ok) return false;
    const output = `${result.stderr}\n${result.stdout}`.toLowerCase();
    return output.includes("invalid surface handle") ||
      output.includes("surface not found");
  }

  private surfaceUnavailableResult(): CommandResult {
    return {
      ok: false,
      status: null,
      stdout: "",
      stderr: "",
      surfaceUnavailable: true,
    };
  }
}

"""#
}
