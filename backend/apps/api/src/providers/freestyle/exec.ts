import { DriverError, type GuestExecResult } from "../contract.ts"

/**
 * Freestyle `exec-await` as root with stdin (cx-kvmz; the web twin is freestyle.ts execWithStdin
 * of cx-psxg). A plain fetch with only the API key header: no background header, so the provider
 * answers inline and stores no result of the call, and the stdin (a person key) exists only in
 * this one request. The caller keeps the guest timeout under the provider's background window
 * when the stdin is a key. A 202 (a background answer, which the provider stores) fails the call.
 * No error carries the request, the answer's text or the provider's message: only the HTTP status.
 *
 * Copies nobody zeroes exist for the life of the call: the base64 string and the JSON request
 * body (JS strings), and the runtime's buffers. They stay inside the trusted delivery boundary
 * (#13742 D16 update 4), never in a log, an error or storage.
 */

/**
 * Whether retrying a non-200 answer cannot help. A 404 is a deleted VM. A conflict (409), rate
 * limit (429) or server error (5xx) is temporary, so CloudDO retries it. Any other 4xx refuses the
 * request itself. A 2xx other than 200 (a 202 background answer) or a 3xx (never followed) fails
 * the same way on every try.
 */
export const execStatusFinal = (status: number): boolean => status !== 409 && status !== 429 && status < 500

/**
 * Bound the serialized provider answer before JSON parsing. The bound is the provider's JSON, not the
 * output: the provider escapes each byte a command writes as up to 6 bytes (`\u0000` for a NUL or
 * other control byte, `\ufffd` for an invalid UTF-8 byte), and the file routes' content arrives as
 * base64 inside that JSON. So it must hold the largest answer a supported call gives
 * (cloud-machine-guest.ts): an exec's two output streams of OUTPUT_MAX_BYTES each at 6x (12 MiB), a
 * FILE_MAX_BYTES read as base64 (about 10.7 MiB), or a directory listing of at most DIR_MAX_BYTES at 6x
 * (12 MiB). freestyle-exec-errors.test.ts checks all three.
 */
export const EXEC_RESPONSE_MAX_BYTES = 16 * 1024 * 1024
/** Read events per answer, so a provider streaming empty or tiny chunks cannot loop until the HTTP timeout. */
export const EXEC_RESPONSE_MAX_CHUNKS = 65_536

const readExecAnswer = async (res: Response): Promise<unknown> => {
  if (!res.body) throw new Error("missing exec body")
  const reader = res.body.getReader()
  // Decoded as it arrives (a character split across chunks stays whole), so no chunk is kept.
  const decoder = new TextDecoder()
  const parts: Array<string> = []
  let bytes = 0
  let reads = 0
  let finished = false
  try {
    for (;;) {
      const next = await reader.read()
      if (next.done) {
        finished = true
        break
      }
      bytes += next.value.byteLength
      reads++
      if (bytes > EXEC_RESPONSE_MAX_BYTES || reads > EXEC_RESPONSE_MAX_CHUNKS)
        throw new DriverError("cloud.exec.output_limit", "guest exec: output exceeded the response limit", true)
      parts.push(decoder.decode(next.value, { stream: true }))
    }
    parts.push(decoder.decode())
    return JSON.parse(parts.join("")) as unknown
  } finally {
    // Over-limit or broken streams stop downloading immediately; the provider's guest timeout remains.
    if (!finished) await reader.cancel().catch(() => undefined)
    reader.releaseLock()
  }
}

const b64 = (bytes: Uint8Array): string => {
  let s = ""
  for (let i = 0; i < bytes.byteLength; i++) s += String.fromCharCode(bytes[i]!)
  return btoa(s)
}

export const freestyleExecStdin = async (
  fetchFn: typeof fetch,
  baseUrl: string,
  apiKey: string,
  id: string,
  command: string,
  stdin: Uint8Array | null,
  timeoutMs: number
): Promise<GuestExecResult> => {
  let res: Response
  try {
    res = await fetchFn(`${baseUrl.replace(/\/+$/, "")}/v5/vms/${encodeURIComponent(id)}/exec-await`, {
      method: "POST",
      headers: { authorization: `Bearer ${apiKey}`, "content-type": "application/json" },
      body: JSON.stringify({ command, timeoutMs, linuxUser: "root", ...(stdin ? { stdin: b64(stdin) } : {}) }),
      // A 3xx is not followed: it fails as not-200, so the stdin is never sent to a Location host.
      redirect: "manual",
      signal: AbortSignal.timeout(timeoutMs + 10_000)
    })
  } catch {
    throw new DriverError("cloud.provider.unavailable", "guest exec: no answer", false)
  }
  if (res.status !== 200) {
    await res.body?.cancel().catch(() => undefined)
    throw new DriverError(res.status === 404 ? "cloud.provider.vm_missing" : "cloud.provider.unavailable", `guest exec: ${res.status}`, execStatusFinal(res.status))
  }
  let r: { stdout?: unknown; stderr?: unknown; statusCode?: unknown }
  try {
    r = (await readExecAnswer(res)) as typeof r
  } catch (error) {
    if (error instanceof DriverError) throw error
    throw new DriverError("cloud.provider.unavailable", "guest exec: unreadable answer", true)
  }
  // statusCode is null when the guest killed the command at its timeout.
  return { exitCode: typeof r.statusCode === "number" ? r.statusCode : 124, stdout: typeof r.stdout === "string" ? r.stdout : "", stderr: typeof r.stderr === "string" ? r.stderr : "" }
}
