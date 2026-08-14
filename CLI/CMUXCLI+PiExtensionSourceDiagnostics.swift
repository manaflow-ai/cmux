extension CMUXCLI {
    static let piExtensionSourceDiagnostics = #"""
type CommandFailureReason = "timeout" | "nonzero-exit" | "spawn-error" | "cancelled";
type CommandTerminationReason = "timeout" | "cancelled";

// Loaded repositories have produced successful 9s+ lifecycle hooks. Leave
// headroom above that observed tail without allowing a stuck child to block a
// session's serialized control queue indefinitely.
const defaultPiHookTimeoutMilliseconds = 15_000;
const maximumPiHookTimeoutMilliseconds = 60_000;

function piHookTimeoutMilliseconds(
  rawValue: string | undefined = process.env.CMUX_PI_HOOK_TIMEOUT_MS,
): number {
  const normalized = rawValue?.trim();
  if (!normalized || !/^\d+$/.test(normalized)) return defaultPiHookTimeoutMilliseconds;
  const parsed = Number(normalized);
  if (!Number.isFinite(parsed) || parsed <= 0) return defaultPiHookTimeoutMilliseconds;
  if (parsed >= maximumPiHookTimeoutMilliseconds) return maximumPiHookTimeoutMilliseconds;
  return Number.isSafeInteger(parsed) ? parsed : defaultPiHookTimeoutMilliseconds;
}

function commandFailureReason(
  status: number | null,
  error: unknown,
  terminationReason?: CommandTerminationReason,
): CommandFailureReason | undefined {
  if (terminationReason) return terminationReason;
  if (status === 0 && error === undefined) return undefined;
  if (status !== null && status !== 0) return "nonzero-exit";
  return "spawn-error";
}

function piHookName(args: string[]): string {
  if (args[0] === "hooks" && args[1] === "pi") {
    return firstString(args[2]) || "unknown";
  }
  if (args[0] === "hooks" && args[1] === "feed") {
    const eventIndex = args.indexOf("--event");
    const eventName = eventIndex >= 0 ? firstString(args[eventIndex + 1]) : null;
    return eventName ? `feed:${eventName}` : "feed";
  }
  if (args[0] === "--json" && args[1] === "surface" && args[2] === "resume") {
    return `surface-resume-${firstString(args[3]) || "unknown"}`;
  }
  return "cmux-command";
}

function expandedPiHookLogPath(value: string): string {
  if (value === "~") return process.env.HOME || value;
  if (value.startsWith("~/") && process.env.HOME) {
    return path.join(process.env.HOME, value.slice(2));
  }
  return value;
}

function piHookDiagnosticPath(): string {
  const explicit = firstString(process.env.CMUX_DEBUG_LOG);
  if (explicit) return expandedPiHookLogPath(explicit);

  const socketPath = firstString(process.env.CMUX_SOCKET_PATH, process.env.CMUX_SOCKET);
  if (socketPath) {
    const socketName = path.basename(socketPath);
    if (socketName.startsWith("cmux-debug-") && socketName.endsWith(".sock")) {
      return path.join("/tmp", `${socketName.slice(0, -".sock".length)}.log`);
    }
  }
  return "/tmp/cmux-debug.log";
}

function appendPiHookDiagnostic(payload: Record<string, unknown>): void {
  let line: string;
  try {
    line = JSON.stringify({ timestamp: new Date().toISOString(), ...payload });
  } catch (_) {
    line = JSON.stringify({
      timestamp: new Date().toISOString(),
      source: "cmux-pi-extension",
      level: "warning",
      message: "failed to serialize Pi hook diagnostic",
      hook_name: "extension",
      reason: "serialization-error",
      timeout_ms: piHookTimeoutMilliseconds(),
      elapsed_ms: 0,
    });
  }
  try {
    void fs.promises.appendFile(piHookDiagnosticPath(), `${line}\n`, "utf8").catch(() => {});
  } catch (_) {}
}

function commandFailureDetails(
  args: string[],
  result: CommandResult,
): Record<string, unknown> {
  return {
    hook_name: piHookName(args),
    reason: result.reason || commandFailureReason(result.status, result.error) || "spawn-error",
    timeout_ms: result.timeoutMs,
    elapsed_ms: result.elapsedMs,
    status: result.status,
    stderr_available: result.stderr.trim().length > 0,
    error_available: result.error !== undefined,
  };
}
"""#
}
