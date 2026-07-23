extension CMUXCLI {
    static let piExtensionSourceDispatch = #"""
class PiCmuxCommandDispatcher {
  private static readonly surfaceUnavailableExitCode = 69;
  private static readonly maxPendingFeedCommands = 8;
  private static readonly maxCompactedTerminalSummaries = 64;
  // Leave headroom for the feed.push envelope under the relay's 16 KiB frame limit.
  private static readonly maxFeedInputBytes = 12 * 1024;
  private static readonly feedDrainDeadlineMs = 2500;
  private controlQueue: Promise<void> = Promise.resolve();
  private pendingFeedCommands = new Map<string, PiFeedCommand>();
  private pendingFeedKeysBySession = new Map<string | null, string[]>();
  private priorityFeedCommands = new Map<string | null, PiFeedCommand[]>();
  private feedDrainWaiters = new Map<string, Array<() => void>>();
  private surfaceState: SurfaceDispatchState = "unknown";
  private didWarnSurfaceUnavailable = false;
  private failedFeedSessions = new Set<string>();
  private activeFeeds = new Map<string | null, {
    cancellation: PiCommandCancellation;
    command: PiFeedCommand;
  }>();

  get canDispatch(): boolean {
    return this.surfaceState !== "unavailable";
  }

  run(
    args: string[],
    cwd: string,
    input: string | undefined,
    context: PiExtensionContextSnapshot,
  ): Promise<CommandResult> {
    const scheduled = this.controlQueue.then(() => this.execute(args, cwd, input, context));
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
    } else {
      if (this.queuedFeedCount(sessionId) >= PiCmuxCommandDispatcher.maxPendingFeedCommands) {
        if (!command.terminal) return;
        if (!this.evictPendingStartForCompletion(sessionId)) {
          this.compactPendingCompletion(command);
          return;
        }
      }
    }
    // Reinsert coalesced entries so per-session order reflects event arrival.
    this.removePendingFeed(key);
    this.appendPendingFeed(key, command);
    this.startNextFeed(sessionId);
  }

  async finishFeedForSession(sessionId: string): Promise<boolean> {
    for (const key of [...(this.pendingFeedKeysBySession.get(sessionId) || [])]) {
      const command = this.removePendingFeed(key);
      if (command?.terminal) this.appendPriorityFeed(command);
    }
    const active = this.activeFeeds.get(sessionId);
    if (active && !active.command.terminal) {
      active.cancellation.cancelled = true;
      active.cancellation.cancel?.();
    }
    this.startNextFeed(sessionId);
    await this.waitForFeedDrainUntilDeadline(sessionId);
    return !this.failedFeedSessions.delete(sessionId);
  }

  private queuedFeedCount(sessionId: string | null): number {
    return (this.pendingFeedKeysBySession.get(sessionId)?.length || 0)
      + (this.priorityFeedCommands.get(sessionId)?.length || 0);
  }

  private appendPendingFeed(key: string, command: PiFeedCommand): void {
    const sessionId = command.context.sessionId;
    const keys = this.pendingFeedKeysBySession.get(sessionId) || [];
    keys.push(key);
    this.pendingFeedKeysBySession.set(sessionId, keys);
    this.pendingFeedCommands.set(key, command);
  }

  private removePendingFeed(key: string): PiFeedCommand | undefined {
    const command = this.pendingFeedCommands.get(key);
    if (!command) return undefined;
    this.pendingFeedCommands.delete(key);
    const sessionId = command.context.sessionId;
    const keys = this.pendingFeedKeysBySession.get(sessionId) || [];
    const index = keys.indexOf(key);
    if (index >= 0) keys.splice(index, 1);
    if (keys.length) this.pendingFeedKeysBySession.set(sessionId, keys);
    else this.pendingFeedKeysBySession.delete(sessionId);
    return command;
  }

  private appendPriorityFeed(command: PiFeedCommand): void {
    const sessionId = command.context.sessionId;
    const commands = this.priorityFeedCommands.get(sessionId) || [];
    commands.push(command);
    this.priorityFeedCommands.set(sessionId, commands);
  }

  private takeNextFeed(sessionId: string | null): PiFeedCommand | undefined {
    const priority = this.priorityFeedCommands.get(sessionId);
    const command = priority?.shift();
    if (priority && !priority.length) this.priorityFeedCommands.delete(sessionId);
    if (command) return command;
    const key = this.pendingFeedKeysBySession.get(sessionId)?.[0];
    return key === undefined ? undefined : this.removePendingFeed(key);
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
        if (this.hasTerminalFeedWork(sessionId)) this.failedFeedSessions.add(sessionId);
        this.discardFeedForSession(sessionId);
        finish();
      }, PiCmuxCommandDispatcher.feedDrainDeadlineMs);
      void drained.then(finish);
    });
  }

  private hasFeedWork(sessionId: string): boolean {
    return this.activeFeeds.has(sessionId) || this.queuedFeedCount(sessionId) > 0;
  }

  private hasTerminalFeedWork(sessionId: string): boolean {
    if (this.activeFeeds.get(sessionId)?.command.terminal) return true;
    if (this.priorityFeedCommands.get(sessionId)?.some((command) => command.terminal)) return true;
    return (this.pendingFeedKeysBySession.get(sessionId) || [])
      .some((key) => this.pendingFeedCommands.get(key)?.terminal);
  }

  private resolveDrainedFeedSession(sessionId: string): void {
    if (this.hasFeedWork(sessionId)) return;
    const waiters = this.feedDrainWaiters.get(sessionId) || [];
    this.feedDrainWaiters.delete(sessionId);
    for (const resolve of waiters) resolve();
  }

  private resolveAllDrainedFeedSessions(): void {
    for (const sessionId of this.feedDrainWaiters.keys()) this.resolveDrainedFeedSession(sessionId);
  }

  private evictPendingStartForCompletion(sessionId: string | null): boolean {
    for (const key of this.pendingFeedKeysBySession.get(sessionId) || []) {
      if (!this.pendingFeedCommands.get(key)?.terminal) {
        this.removePendingFeed(key);
        return true;
      }
    }
    return false;
  }

  private compactPendingCompletion(command: PiFeedCommand): void {
    const sessionId = command.context.sessionId;
    const keys = this.pendingFeedKeysBySession.get(sessionId) || [];
    for (let index = keys.length - 1; index >= 0; index -= 1) {
      const key = keys[index];
      const pending = this.pendingFeedCommands.get(key);
      if (!pending) continue;
      if (!pending.terminal) continue;
      this.pendingFeedCommands.set(key, this.compactedTerminalCommand(pending, command));
      return;
    }
    const priority = this.priorityFeedCommands.get(sessionId) || [];
    for (let index = priority.length - 1; index >= 0; index -= 1) {
      const pending = priority[index];
      if (!pending.terminal) continue;
      priority[index] = this.compactedTerminalCommand(pending, command);
      return;
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
    return { ...command, input: boundedPiFeedInput(payload, PiCmuxCommandDispatcher.maxFeedInputBytes) };
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
    return { ...existing, input: boundedPiFeedInput(existingPayload, PiCmuxCommandDispatcher.maxFeedInputBytes) };
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
    for (const key of ["session_id", "turn_id", "tool_call_id", "tool_name", "cwd"] as const) {
      const value = payload[key];
      if (typeof value === "string") summary[key] = value.slice(0, 2048);
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
    for (const key of this.pendingFeedKeysBySession.get(sessionId) || []) {
      this.pendingFeedCommands.delete(key);
    }
    this.pendingFeedKeysBySession.delete(sessionId);
    this.priorityFeedCommands.delete(sessionId);
    const active = this.activeFeeds.get(sessionId);
    if (active) {
      active.cancellation.cancelled = true;
      active.cancellation.cancel?.();
    }
    this.resolveDrainedFeedSession(sessionId);
  }

  private startNextFeed(sessionId: string | null): void {
    if (this.activeFeeds.has(sessionId)) return;
    if (!this.canDispatch) {
      this.pendingFeedCommands.clear();
      this.pendingFeedKeysBySession.clear();
      this.priorityFeedCommands.clear();
      this.resolveAllDrainedFeedSessions();
      return;
    }
    const command = this.takeNextFeed(sessionId);
    if (!command) return;
    const cancellation: PiCommandCancellation = { cancelled: false };
    this.activeFeeds.set(sessionId, { cancellation, command });
    void this.execute(command.args, command.cwd, command.input, command.context, cancellation)
      .then((result) => {
        if (result.error instanceof Error && result.error.message.includes("timed out after")) {
          const sessionId = command.context.sessionId;
          if (sessionId) {
            if (this.hasTerminalFeedWork(sessionId)) this.failedFeedSessions.add(sessionId);
            this.discardFeedForSession(sessionId);
          }
        } else if (!result.ok && command.terminal && !result.surfaceUnavailable && !cancellation.cancelled) {
          if (sessionId) this.failedFeedSessions.add(sessionId);
        }
      })
      .catch(() => {})
      .finally(() => {
        if (this.activeFeeds.get(sessionId)?.cancellation === cancellation) this.activeFeeds.delete(sessionId);
        this.startNextFeed(sessionId);
        if (sessionId) this.resolveDrainedFeedSession(sessionId);
      });
  }

  private async execute(
    args: string[],
    cwd: string,
    input: string | undefined,
    context: PiExtensionContextSnapshot,
    cancellation?: PiCommandCancellation,
  ): Promise<CommandResult> {
    if (this.surfaceState === "unavailable") {
      return this.surfaceUnavailableResult();
    }

    const result = await this.spawnCmux(args, cwd, input, cancellation);
    if (this.isSurfaceResolutionFailure(result)) {
      this.surfaceState = "unavailable";
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
    if (result.ok && this.surfaceState === "unknown") {
      this.surfaceState = "available";
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
    return !result.ok && result.status === PiCmuxCommandDispatcher.surfaceUnavailableExitCode;
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
