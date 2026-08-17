extension CMUXCLI {
    static let piExtensionSourceDiagnostics = #"""
type CommandFailureReason = "timeout" | "nonzero-exit" | "spawn-error" | "cancelled";
type CommandTerminationReason = "timeout" | "cancelled";

// Loaded repositories have produced successful 9s+ lifecycle hooks. Leave
// headroom above that observed tail without allowing a stuck child to block a
// session's serialized control queue indefinitely.
const defaultPiHookTimeoutMilliseconds = 15_000;
const maximumPiHookTimeoutMilliseconds = 60_000;
// Feed's CLI owns a four-second end-to-end deadline. Give the wrapper enough
// headroom that the child reports that outcome itself instead of being killed
// mid-deadline, while lifecycle tuning still cannot pin the shared Feed pool.
const maximumPiFeedCommandTimeoutMilliseconds = 4_500;
// Diagnostics are best effort and may hold a serialized hook queue only briefly.
const piHookDiagnosticWriteDeadlineMilliseconds = 100;

function piHookTimeoutMilliseconds(
  rawValue: string | undefined = process.env.CMUX_PI_HOOK_TIMEOUT_MS,
): number {
  const normalized = rawValue?.trim();
  if (!normalized || !/^\d+$/.test(normalized)) return defaultPiHookTimeoutMilliseconds;
  const parsed = Number(normalized);
  if (parsed >= maximumPiHookTimeoutMilliseconds) return maximumPiHookTimeoutMilliseconds;
  return Number.isSafeInteger(parsed) && parsed > 0 ? parsed : defaultPiHookTimeoutMilliseconds;
}

function piCommandTimeoutMilliseconds(
  args: string[],
  rawValue: string | undefined = process.env.CMUX_PI_HOOK_TIMEOUT_MS,
): number {
  const configured = piHookTimeoutMilliseconds(rawValue);
  return args[0] === "hooks" && args[1] === "feed"
    ? Math.min(configured, maximumPiFeedCommandTimeoutMilliseconds)
    : configured;
}

function commandFailureReason(
  status: number | null,
  error: unknown,
  terminationReason?: CommandTerminationReason,
): CommandFailureReason | undefined {
  if (terminationReason) return terminationReason;
  if (status === 0) return undefined;
  if (status !== null && status !== 0) return "nonzero-exit";
  return "spawn-error";
}

function boundedPiHookName(value: string): string {
  return utf8Prefix(value, 128) || "unknown";
}

function piHookName(args: string[]): string {
  if (args[0] === "hooks" && args[1] === "pi") {
    return boundedPiHookName(firstString(args[2]) || "unknown");
  }
  if (args[0] === "hooks" && args[1] === "feed") {
    const eventIndex = args.indexOf("--event");
    const eventName = eventIndex >= 0 ? firstString(args[eventIndex + 1]) : null;
    return boundedPiHookName(eventName ? `feed:${eventName}` : "feed");
  }
  if (args[0] === "--json" && args[1] === "surface" && args[2] === "resume") {
    return boundedPiHookName(`surface-resume-${firstString(args[3]) || "unknown"}`);
  }
  return "cmux-command";
}

function expandedPiHookLogPath(value: string, home: string | undefined = process.env.HOME): string {
  if (value === "~") return home || value;
  if (value.startsWith("~/") && home) {
    return path.join(home, value.slice(2));
  }
  return value;
}

function isOwnedRegularPiHookFile(metadata: fs.Stats): boolean {
  return metadata.isFile()
    && typeof process.getuid === "function"
    && metadata.uid === process.getuid();
}

let activePiHookDiagnosticWrite: Promise<void> | undefined;

async function runPiHookDiagnosticWrite(operation: () => Promise<void>): Promise<void> {
  // Retain at most one file operation. If it stalls after the caller's deadline,
  // later diagnostics are dropped instead of accumulating promises or handles.
  if (activePiHookDiagnosticWrite) return;
  let tracked: Promise<void>;
  tracked = Promise.resolve()
    .then(operation)
    .catch(() => {})
    .finally(() => {
      if (activePiHookDiagnosticWrite === tracked) activePiHookDiagnosticWrite = undefined;
    });
  activePiHookDiagnosticWrite = tracked;

  let deadline: ReturnType<typeof setTimeout> | undefined;
  try {
    await Promise.race([
      tracked,
      new Promise<void>((resolve) => {
        deadline = setTimeout(resolve, piHookDiagnosticWriteDeadlineMilliseconds);
      }),
    ]);
  } finally {
    if (deadline !== undefined) clearTimeout(deadline);
  }
}

function piHookDiagnosticPath(
  environment: Record<string, string | undefined> = process.env,
  lastDebugLogPathFile = "/tmp/cmux-last-debug-log-path",
  fallbackLogPath = "/tmp/cmux-debug.log",
): string {
  const explicit = firstString(environment.CMUX_DEBUG_LOG);
  if (explicit) return expandedPiHookLogPath(explicit, environment.HOME);

  const socketPath = firstString(environment.CMUX_SOCKET_PATH, environment.CMUX_SOCKET);
  if (socketPath) {
    const socketName = path.basename(socketPath);
    if (socketName.startsWith("cmux-debug-") && socketName.endsWith(".sock")) {
      return path.join("/tmp", `${socketName.slice(0, -".sock".length)}.log`);
    }
  }

  let pointerDescriptor: number | undefined;
  try {
    // The shared pointer is untrusted: inspect a nonblocking descriptor and
    // bound the read so a special or oversized file cannot stall Pi.
    pointerDescriptor = fs.openSync(
      lastDebugLogPathFile,
      fs.constants.O_RDONLY | fs.constants.O_NONBLOCK | fs.constants.O_NOFOLLOW,
    );
    if (isOwnedRegularPiHookFile(fs.fstatSync(pointerDescriptor))) {
      const pointerContents = Buffer.alloc(4096);
      const bytesRead = fs.readSync(
        pointerDescriptor,
        pointerContents,
        0,
        pointerContents.byteLength,
        0,
      );
      const lastPath = firstString(pointerContents.subarray(0, bytesRead).toString("utf8"));
      if (lastPath) return expandedPiHookLogPath(lastPath, environment.HOME);
    }
  } catch (_) {
  } finally {
    if (pointerDescriptor !== undefined) {
      try { fs.closeSync(pointerDescriptor); } catch (_) {}
    }
  }
  return fallbackLogPath;
}

async function appendPiHookDiagnostic(
  payload: Record<string, unknown>,
  environment: Record<string, string | undefined> = process.env,
  lastDebugLogPathFile = "/tmp/cmux-last-debug-log-path",
  fallbackLogPath = "/tmp/cmux-debug.log",
): Promise<void> {
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
    // Read/write permits checking the existing JSONL boundary, while O_NONBLOCK
    // keeps special files such as a FIFO from stalling Pi's lifecycle queue.
    const flags = fs.constants.O_RDWR
      | fs.constants.O_APPEND
      | fs.constants.O_CREAT
      | fs.constants.O_NONBLOCK
      | fs.constants.O_NOFOLLOW;
    const handle = await fs.promises.open(
      piHookDiagnosticPath(environment, lastDebugLogPathFile, fallbackLogPath),
      flags,
      0o600,
    );
    try {
      const metadata = await handle.stat();
      // cmux diagnostics are files; drop device, socket, and pipe destinations.
      if (!isOwnedRegularPiHookFile(metadata)) return;
      let prefix = "";
      if (metadata.size > 0) {
        const trailingByte = Buffer.alloc(1);
        const { bytesRead } = await handle.read(trailingByte, 0, 1, metadata.size - 1);
        if (bytesRead !== 1 || trailingByte[0] !== 0x0a) prefix = "\n";
      }
      await handle.writeFile(`${prefix}${line}\n`, "utf8");
    } finally {
      try { await handle.close(); } catch (_) {}
    }
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
