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
  private controlQueue: Promise<void> = Promise.resolve();
  private pendingFeedCommands = new Map<string, PiFeedCommand>();
  private routableState: SurfaceDispatchState = "unknown";
  private explicitSurfaceUnavailable = false;
  private didWarnSurfaceUnavailable = false;
  private feedRunning = false;
  private activeFeed: {
    sessionId: string | null;
    cancellation: PiCommandCancellation;
    command: PiFeedCommand;
    finished: Promise<void>;
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

    const existing = this.pendingFeedCommands.get(key);
    if (existing) {
      // Once a completion is pending for a tool, never replace it with a late start event.
      if (existing.terminal && !command.terminal) return;
      this.pendingFeedCommands.set(key, command);
    } else {
      if (this.pendingFeedCommands.size >= PiCmuxCommandDispatcher.maxPendingFeedCommands) {
        if (!command.terminal) return;
        this.evictFeedForCompletion();
      }
      this.pendingFeedCommands.set(key, command);
    }
    this.startNextFeed();
  }

  async finishFeedForSession(sessionId: string): Promise<void> {
    const terminals: PiFeedCommand[] = [];
    for (const [key, command] of this.pendingFeedCommands) {
      if (command.context.sessionId !== sessionId) continue;
      this.pendingFeedCommands.delete(key);
      if (command.terminal) terminals.push(command);
    }
    const active = this.activeFeed?.sessionId === sessionId ? this.activeFeed : null;
    if (active && !active.command.terminal) {
      active.cancellation.cancelled = true;
      active.cancellation.cancel?.();
    }
    if (active) await active.finished;
    await Promise.all(terminals.map((command) =>
      this.execute(command.args, command.cwd, command.input, command.context)
    ));
  }

  private evictFeedForCompletion(): void {
    for (const [key, command] of this.pendingFeedCommands) {
      if (!command.terminal) {
        this.pendingFeedCommands.delete(key);
        return;
      }
    }
    // The queue is all completions; retain the most recent bounded set.
    const oldest = this.pendingFeedCommands.keys().next();
    if (!oldest.done) this.pendingFeedCommands.delete(oldest.value);
  }

  private startNextFeed(): void {
    if (this.feedRunning) return;
    if (!this.canDispatch) {
      this.pendingFeedCommands.clear();
      return;
    }
    const next = this.pendingFeedCommands.entries().next();
    if (next.done) return;
    const [key, command] = next.value;
    this.pendingFeedCommands.delete(key);
    this.feedRunning = true;
    const cancellation: PiCommandCancellation = { cancelled: false };
    let finishActiveFeed: () => void = () => {};
    const finished = new Promise<void>((resolve) => {
      finishActiveFeed = resolve;
    });
    this.activeFeed = { sessionId: command.context.sessionId, cancellation, command, finished };
    void this.execute(command.args, command.cwd, command.input, command.context, cancellation)
      .catch(() => {})
      .finally(() => {
        if (this.activeFeed?.cancellation === cancellation) this.activeFeed = null;
        this.feedRunning = false;
        finishActiveFeed();
        this.startNextFeed();
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

const cmuxCommandDispatcher = new PiCmuxCommandDispatcher();

function runCmux(
  args: string[],
  cwd: string,
  input: string | undefined,
  context: PiExtensionContextSnapshot,
  scope: PiCmuxCommandScope = "routable",
): Promise<CommandResult> {
  return cmuxCommandDispatcher.run(args, cwd, input, context, scope);
}

function enqueueCmuxFeed(key: string, command: PiFeedCommand): void {
  cmuxCommandDispatcher.enqueueFeed(key, command);
}
"""#
}
