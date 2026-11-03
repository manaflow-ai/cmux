import { pathToFileURL } from "node:url";
import { NodeClient } from "../src/node.ts";
import { CloudClient, cloudTransportFromEnvironment } from "./cloud.ts";

// Arm this in the actual payload, after bwrap has finished its namespace and
// credential setup (those transitions can clear a parent's death signal).
// Killing namespace PID 1 already ends its processes; arming the payload
// itself avoids relying on a signal inherited through fork/exec.
if (process.platform === "linux") {
  const parent = process.ppid;
  const { dlopen, FFIType } = await import("bun:ffi");
  const libc = dlopen("libc.so.6", {
    prctl: { args: [FFIType.i32, FFIType.u64, FFIType.u64, FFIType.u64, FFIType.u64], returns: FFIType.i32 },
  });
  try {
    // PR_SET_PDEATHSIG=1, SIGKILL=9. Check again to close the arm/parent-exit race.
    if (libc.symbols.prctl(1, 9, 0, 0, 0) !== 0 || process.ppid !== parent || parent === 0) {
      throw new Error("cmux run: could not bind script lifetime to its sandbox parent");
    }
  } finally {
    libc.close();
  }
}

const script = Bun.argv[2];
if (!script) throw new Error("cmux run needs a script path");

const socketPath = process.env.CMUX_TUI_SOCKET;
const session = process.env.CMUX_TUI_SESSION;
if (!socketPath && !session) throw new Error("CMUX_TUI_SOCKET or CMUX_TUI_SESSION is required");

const client = new NodeClient(socketPath ? { socketPath } : { session });
const cloudTransport = cloudTransportFromEnvironment();
const cloud = cloudTransport ? new CloudClient(cloudTransport) : undefined;
Object.defineProperty(globalThis, "cmux", {
  configurable: false,
  enumerable: true,
  value: client,
  writable: false,
});
Object.defineProperty(globalThis, "cmuxCloud", {
  configurable: false,
  enumerable: true,
  value: cloud,
  writable: false,
});
Object.defineProperty(globalThis, "cmuxArgs", {
  configurable: false,
  enumerable: true,
  value: Bun.argv.slice(3),
  writable: false,
});

try {
  await import(pathToFileURL(script).href);
} finally {
  client.close();
  cloud?.close();
}
