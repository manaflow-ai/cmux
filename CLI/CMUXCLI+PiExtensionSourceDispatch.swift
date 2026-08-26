extension CMUXCLI {
    static let piExtensionSourceDispatch = #"""
function piFeedValueSummary(value: unknown): Record<string, unknown> {
  if (value === null) return { kind: "null" };
  if (typeof value === "string") return { kind: "text", length: value.length };
  if (typeof value === "boolean" || typeof value === "number") return { kind: typeof value };
  if (Array.isArray(value)) return { kind: "array" };
  return { kind: typeof value };
}

function piTerminalFeedSummary(payload: Record<string, unknown>): Record<string, unknown> {
  const summary: Record<string, unknown> = {};
  for (const key of ["session_id", "turn_id", "tool_call_id", "tool_name", "cwd"] as const) {
    const value = payload[key];
    if (typeof value === "string") summary[key] = value.slice(0, 2048);
  }
  if (typeof payload.is_error === "boolean") summary.is_error = payload.is_error;
  if (payload.tool_result !== undefined) summary.tool_result = piFeedValueSummary(payload.tool_result);
  return summary;
}

class PiCmuxCommandDispatcher {
  private static readonly surfaceUnavailableExitCode = 69;
  private static readonly maxPendingFeedCommands = 8;
  private static readonly maxQueuedFeedCommands = 32;
  private static readonly maxActiveFeedCommands = 2;
  private static readonly maxCompactedTerminalSummaries = 64;
  // Leave headroom for the feed.push envelope under the relay's 16 KiB frame limit.
  private static readonly maxFeedInputBytes = 12 * 1024;
  // The app may spend three seconds committing acknowledged Feed ingress and the
  // CLI owns a four-second end-to-end deadline. Observe that outcome before the
  // extension classifies a terminal delivery as failed.
  private static readonly feedDrainDeadlineMs = 4500;
  private controlQueues = new Map<string | null, Promise<void>>();
  private pendingFeedCommands = new Map<string, PiFeedCommand>();
  private pendingFeedKeysBySession = new Map<string | null, string[]>();
  private priorityFeedCommands = new Map<string | null, PiFeedCommand[]>();
  private feedDrainWaiters = new Map<string, Array<() => void>>();
  private feedSessionQueue: Array<string | null> = [];
  private scheduledFeedSessions = new Set<string | null>();
  private unavailableSessions = new Set<string>();
  private activeFeeds = new Map<string | null, {
    cancellation: PiCommandCancellation;
    command: PiFeedCommand;
  }>();
  canDispatch(sessionId: string | null): boolean {
    return !sessionId || !this.unavailableSessions.has(sessionId);
  }
  releaseSession(sessionId: string): void {
    this.unavailableSessions.delete(sessionId);
  }

  run(
    args: string[],
    cwd: string,
    input: string | undefined,
    context: PiExtensionContextSnapshot,
  ): Promise<CommandResult> {
    const sessionId = context.sessionId;
    const previous = this.controlQueues.get(sessionId) || Promise.resolve();
    const scheduled = previous.then(() => this.execute(args, cwd, input, context));
    let tail: Promise<void>;
    tail = scheduled
      .then(() => undefined, () => undefined)
      .finally(() => {
        if (this.controlQueues.get(sessionId) === tail) this.controlQueues.delete(sessionId);
      });
    this.controlQueues.set(sessionId, tail);
    return scheduled;
  }
  enqueueFeed(key: string, command: PiFeedCommand): void {
    const sessionId = command.context.sessionId;
    if (!this.canDispatch(sessionId)) {
      if (command.terminal) command.onFailure?.();
      return;
    }
    const existing = this.pendingFeedCommands.get(key);
    if (existing) {
      // Once a completion is pending for a tool, never replace it with a late start event.
      if (existing.terminal && !command.terminal) return;
    } else {
      if (this.queuedFeedCount(sessionId) >= PiCmuxCommandDispatcher.maxPendingFeedCommands) {
        if (!command.terminal) return;
        if (!this.evictPendingStartForCompletion(sessionId)) {
          if (!this.compactPendingCompletion(command)) command.onFailure?.();
          return;
        }
      }
      if (this.totalQueuedFeedCount() >= PiCmuxCommandDispatcher.maxQueuedFeedCommands) {
        if (!command.terminal) return;
        if (!this.evictAnyPendingStart()) {
          if (!this.compactPendingCompletion(command)) command.onFailure?.();
          return;
        }
      }
    }
    // Reinsert coalesced entries so per-session order reflects event arrival.
    this.removePendingFeed(key);
    this.appendPendingFeed(key, command);
    this.scheduleFeed(sessionId);
  }
  async finishFeedForSession(sessionId: string): Promise<void> {
    for (const key of [...(this.pendingFeedKeysBySession.get(sessionId) || [])]) {
      const command = this.removePendingFeed(key);
      if (command?.terminal) this.appendPriorityFeed(command);
    }
    const active = this.activeFeeds.get(sessionId);
    if (active && !active.command.terminal) {
      active.cancellation.cancelled = true;
      active.cancellation.cancel?.();
    }
    this.scheduleFeed(sessionId);
    await this.waitForFeedDrainUntilDeadline(sessionId);
  }
  private queuedFeedCount(sessionId: string | null): number {
    return (this.pendingFeedKeysBySession.get(sessionId)?.length || 0)
      + (this.priorityFeedCommands.get(sessionId)?.length || 0);
  }

  private totalQueuedFeedCount(): number {
    let count = this.pendingFeedCommands.size;
    for (const commands of this.priorityFeedCommands.values()) count += commands.length;
    return count;
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
        this.failTerminalFeedForSession(sessionId);
        this.discardFeedForSession(sessionId);
        finish();
      }, PiCmuxCommandDispatcher.feedDrainDeadlineMs);
      void drained.then(finish);
    });
  }

  private hasFeedWork(sessionId: string): boolean {
    return this.activeFeeds.has(sessionId) || this.queuedFeedCount(sessionId) > 0;
  }

  private resolveDrainedFeedSession(sessionId: string): void {
    if (this.hasFeedWork(sessionId)) return;
    const waiters = this.feedDrainWaiters.get(sessionId) || [];
    this.feedDrainWaiters.delete(sessionId);
    for (const resolve of waiters) resolve();
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

  private failTerminalFeedForSession(sessionId: string): void {
    const active = this.activeFeeds.get(sessionId)?.command;
    if (active?.terminal) active.onFailure?.();
    for (const command of this.priorityFeedCommands.get(sessionId) || []) {
      if (command.terminal) command.onFailure?.();
    }
    for (const key of this.pendingFeedKeysBySession.get(sessionId) || []) {
      const command = this.pendingFeedCommands.get(key);
      if (command?.terminal) command.onFailure?.();
    }
  }

  private evictAnyPendingStart(): boolean {
    for (const [key, command] of this.pendingFeedCommands) {
      if (!command.terminal) {
        this.removePendingFeed(key);
        return true;
      }
    }
    return false;
  }

  private compactPendingCompletion(command: PiFeedCommand): boolean {
    const sessionId = command.context.sessionId;
    const keys = this.pendingFeedKeysBySession.get(sessionId) || [];
    for (let index = keys.length - 1; index >= 0; index -= 1) {
      const key = keys[index];
      const pending = this.pendingFeedCommands.get(key);
      if (!pending) continue;
      if (!pending.terminal) continue;
      this.pendingFeedCommands.set(key, this.compactedTerminalCommand(pending, command));
      return true;
    }
    const priority = this.priorityFeedCommands.get(sessionId) || [];
    for (let index = priority.length - 1; index >= 0; index -= 1) {
      const pending = priority[index];
      if (!pending.terminal) continue;
      priority[index] = this.compactedTerminalCommand(pending, command);
      return true;
    }
    return false;
  }

  private compactedTerminalCommand(existing: PiFeedCommand, incoming: PiFeedCommand): PiFeedCommand {
    const existingPayload = { ...existing.payload };
    const incomingPayload = incoming.payload;
    const existingSummaries = Array.isArray(existingPayload.cmux_compacted_terminal_events)
      ? existingPayload.cmux_compacted_terminal_events
      : [piTerminalFeedSummary(existingPayload)];
    const incomingSummaries = Array.isArray(incomingPayload.cmux_compacted_terminal_events)
      ? incomingPayload.cmux_compacted_terminal_events
      : [piTerminalFeedSummary(incomingPayload)];
    const existingCount = this.compactedTerminalCount(existingPayload, existingSummaries.length);
    const incomingCount = this.compactedTerminalCount(incomingPayload, incomingSummaries.length);
    const combined = [...existingSummaries, ...incomingSummaries];
    const summaryLimit = PiCmuxCommandDispatcher.maxCompactedTerminalSummaries;
    const summaries = combined.length <= summaryLimit
      ? combined
      : [...combined.slice(0, summaryLimit / 2), ...combined.slice(-summaryLimit / 2)];
    const totalCount = existingCount + incomingCount;
    delete existingPayload.tool_input;
    delete existingPayload.tool_result;
    existingPayload.cmux_compacted_terminal_count = totalCount;
    existingPayload.cmux_compacted_terminal_omitted_count = Math.max(0, totalCount - summaries.length);
    existingPayload.cmux_compacted_terminal_events = summaries;
    return { ...existing, payload: existingPayload };
  }

  private compactedTerminalCount(payload: Record<string, unknown>, fallback: number): number {
    const count = payload.cmux_compacted_terminal_count;
    return typeof count === "number" && Number.isFinite(count) && count >= fallback ? count : fallback;
  }
  private discardFeedForSession(sessionId: string): void {
    for (const key of this.pendingFeedKeysBySession.get(sessionId) || []) {
      this.pendingFeedCommands.delete(key);
    }
    this.pendingFeedKeysBySession.delete(sessionId);
    this.priorityFeedCommands.delete(sessionId);
    this.scheduledFeedSessions.delete(sessionId);
    this.feedSessionQueue = this.feedSessionQueue.filter((queued) => queued !== sessionId);
    const active = this.activeFeeds.get(sessionId);
    if (active) {
      active.cancellation.cancelled = true;
      active.cancellation.cancel?.();
    }
    this.resolveDrainedFeedSession(sessionId);
  }
  private scheduleFeed(sessionId: string | null): void {
    if (sessionId && !this.canDispatch(sessionId)) {
      this.failTerminalFeedForSession(sessionId);
      this.discardFeedForSession(sessionId);
      return;
    }
    if (!this.activeFeeds.has(sessionId) && this.queuedFeedCount(sessionId) > 0 &&
        !this.scheduledFeedSessions.has(sessionId)) {
      this.scheduledFeedSessions.add(sessionId);
      this.feedSessionQueue.push(sessionId);
    }
    this.startScheduledFeeds();
  }

  private startScheduledFeeds(): void {
    while (this.activeFeeds.size < PiCmuxCommandDispatcher.maxActiveFeedCommands) {
      const sessionId = this.feedSessionQueue.shift();
      if (sessionId === undefined) return;
      this.scheduledFeedSessions.delete(sessionId);
      if (this.activeFeeds.has(sessionId)) continue;
      const command = this.takeNextFeed(sessionId);
      if (!command) {
        if (sessionId) this.resolveDrainedFeedSession(sessionId);
        continue;
      }
      const cancellation: PiCommandCancellation = { cancelled: false };
      this.activeFeeds.set(sessionId, { cancellation, command });
      const input = boundedPiFeedInput(command.payload, PiCmuxCommandDispatcher.maxFeedInputBytes);
      void this.execute(command.args, command.cwd, input, command.context, cancellation)
      .then((result) => {
        if (result.ok && command.context.sessionId) {
          rememberSurfaceTarget(this, command.context.sessionId, result);
        }
        if (result.surfaceUnavailable) {
          const sessionId = command.context.sessionId;
          if (sessionId) {
            this.failTerminalFeedForSession(sessionId);
            this.discardFeedForSession(sessionId);
          }
        } else if (result.reason === "timeout") {
          const sessionId = command.context.sessionId;
          if (sessionId) {
            this.failTerminalFeedForSession(sessionId);
            this.discardFeedForSession(sessionId);
          }
        } else if (!result.ok && command.terminal && !result.surfaceUnavailable && !cancellation.cancelled) {
          command.onFailure?.();
        }
      })
      .catch(() => {})
      .finally(() => {
        if (this.activeFeeds.get(sessionId)?.cancellation === cancellation) this.activeFeeds.delete(sessionId);
        this.scheduleFeed(sessionId);
        if (sessionId) this.resolveDrainedFeedSession(sessionId);
      });
    }
  }

  private async execute(
    args: string[],
    cwd: string,
    input: string | undefined,
    context: PiExtensionContextSnapshot,
    cancellation?: PiCommandCancellation,
  ): Promise<CommandResult> {
    const sessionId = context.sessionId;
    if (!this.canDispatch(sessionId)) {
      return this.surfaceUnavailableResult();
    }

    const result = await this.spawnCmux(args, cwd, input, cancellation);
    const surfaceUnavailable = this.isSurfaceResolutionFailure(result);
    let shouldLogFailure = true;
    if (surfaceUnavailable && sessionId) {
      // Claim synchronously so overlapping Feed/control failures emit one diagnostic.
      shouldLogFailure = !this.unavailableSessions.has(sessionId);
      this.unavailableSessions.add(sessionId);
    }
    if (!result.ok && result.reason !== "cancelled" && shouldLogFailure) {
      await warn(context, "cmux hook command failed", {
        ...commandFailureDetails(args, result),
        ...(surfaceUnavailable ? { surface_unavailable: true, dispatch_disabled: true } : {}),
      });
    }
    if (surfaceUnavailable) {
      return { ...result, surfaceUnavailable: true };
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
      const startedAt = performance.now();
      const timeoutMs = piCommandTimeoutMilliseconds(args);
      let settled = false;
      let stdout = "";
      let stderr = "";
      let inputError: unknown;
      let timeout: ReturnType<typeof setTimeout> | null = null;
      let terminateGrace: ReturnType<typeof setTimeout> | null = null;
      let forceSettleTimeout: ReturnType<typeof setTimeout> | null = null;
      let terminationError: Error | undefined;
      let terminationReason: CommandTerminationReason | undefined;

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
      const elapsedMilliseconds = (): number => (
        Math.max(0, Math.round(performance.now() - startedAt))
      );
      const terminatedResult = (): CommandResult => ({
        ok: false,
        status: null,
        stdout,
        stderr,
        error: terminationError,
        reason: commandFailureReason(null, terminationError, terminationReason),
        timeoutMs,
        elapsedMs: elapsedMilliseconds(),
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
        const beginTermination = (reason: CommandTerminationReason, error: Error) => {
          if (terminationError) return;
          terminationError = error;
          terminationReason = reason;
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
          settle(terminationError ? terminatedResult() : {
            ok: false,
            status: null,
            stdout,
            stderr,
            error,
            reason: commandFailureReason(null, error),
            timeoutMs,
            elapsedMs: elapsedMilliseconds(),
          });
        });
        child.on("close", (code) => {
          if (terminationError) {
            settle(terminatedResult());
            return;
          }
          const status = typeof code === "number" ? code : null;
          const error = inputError;
          const reason = commandFailureReason(status, error);
          settle({
            ok: reason === undefined,
            status,
            stdout,
            stderr,
            error,
            reason,
            timeoutMs,
            elapsedMs: elapsedMilliseconds(),
          });
        });
        if (cancellation) {
          cancellation.cancel = () => beginTermination("cancelled", new Error("cmux feed command cancelled"));
          if (cancellation.cancelled) cancellation.cancel();
        }
        timeout = setTimeout(() => {
          beginTermination("timeout", new Error(`cmux command timed out after ${timeoutMs}ms`));
        }, timeoutMs);
        child.stdin.end(input);
      } catch (error) {
        settle({
          ok: false,
          status: null,
          stdout,
          stderr,
          error,
          reason: commandFailureReason(null, error),
          timeoutMs,
          elapsedMs: elapsedMilliseconds(),
        });
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
      timeoutMs: piHookTimeoutMilliseconds(),
      elapsedMs: 0,
      surfaceUnavailable: true,
    };
  }
}

"""#
}
