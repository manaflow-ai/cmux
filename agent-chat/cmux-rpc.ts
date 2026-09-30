// Calls the cmux app's control socket through the bundled CLI (`cmux rpc`).
// The app passes CMUX_BUNDLED_CLI_PATH and CMUX_SOCKET_PATH to the sidecar it
// launches; a manually started sidecar falls back to `cmux` on PATH.

export interface CmuxRpcResult { ok: boolean; result?: unknown; error?: string; errorCode?: "timeout" }

const RPC_TIMEOUT_MS = 10_000;

async function readText(reader: ReadableStreamDefaultReader<Uint8Array>): Promise<string> {
  const decoder = new TextDecoder();
  const chunks: string[] = [];
  try {
    while (true) {
      const { value, done } = await reader.read();
      if (done) break;
      chunks.push(decoder.decode(value, { stream: true }));
    }
    chunks.push(decoder.decode());
    return chunks.join("");
  } finally {
    reader.releaseLock();
  }
}

export async function cmuxRpc(method: string, params: Record<string, unknown>): Promise<CmuxRpcResult> {
  const cli = process.env.CMUX_BUNDLED_CLI_PATH?.trim() || "cmux";
  let proc: ReturnType<typeof Bun.spawn>;
  try {
    proc = Bun.spawn([cli, "rpc", method, JSON.stringify(params)], {
      stdin: "ignore",
      stdout: "pipe",
      stderr: "pipe",
      env: process.env,
    });
  } catch (err) {
    return { ok: false, error: `cmux CLI unavailable: ${err instanceof Error ? err.message : String(err)}` };
  }
  const stdoutReader = (proc.stdout as ReadableStream<Uint8Array>).getReader();
  const stderrReader = (proc.stderr as ReadableStream<Uint8Array>).getReader();
  const retire = () => {
    // A wrapper may ignore SIGTERM, or already have exited while a child keeps
    // its pipes open. Neither process exit nor pipe closure owns the deadline.
    try { proc.kill("SIGKILL"); } catch {}
    void stdoutReader.cancel().catch(() => {});
    void stderrReader.cancel().catch(() => {});
  };
  let timer: ReturnType<typeof setTimeout>;
  let settled = false;
  const deadline = new Promise<CmuxRpcResult>((resolve) => {
    timer = setTimeout(() => {
      if (settled) return;
      resolve({ ok: false, error: "ETIMEDOUT", errorCode: "timeout" });
      retire();
    }, RPC_TIMEOUT_MS);
  });
  const completion = Promise.all([readText(stdoutReader), readText(stderrReader), proc.exited]).then(([stdout, stderr, code]): CmuxRpcResult => {
    if (code !== 0) return { ok: false, error: (stderr.trim() || stdout.trim() || `cmux rpc exited ${code}`).slice(0, 300) };
    try {
      return { ok: true, result: JSON.parse(stdout) };
    } catch {
      return { ok: true, result: stdout.trim() };
    }
  });
  try {
    return await Promise.race([completion, deadline]);
  } catch (err) {
    retire();
    return { ok: false, error: String(err) };
  } finally {
    settled = true;
    clearTimeout(timer!);
  }
}
