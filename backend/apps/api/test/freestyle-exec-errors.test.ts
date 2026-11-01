import { describe, expect, it } from "vitest"
import { DriverError } from "../src/providers/contract.ts"
import { DIR_MAX_BYTES, DIR_MAX_ENTRIES, FILE_MAX_BYTES, OUTPUT_MAX_BYTES } from "../src/cloud-machine-guest.ts"
import { EXEC_RESPONSE_MAX_BYTES, EXEC_RESPONSE_MAX_CHUNKS, freestyleExecStdin } from "../src/providers/freestyle/exec.ts"

/**
 * Freestyle guest exec failures: CloudDO retries an error that is not `final`, so a temporary
 * provider outage (409, 429, 5xx, no answer) must stay retryable, and only a request the provider
 * will always refuse may stop the operation.
 */
const answering = (status: number): typeof fetch => async () => new Response(status === 200 ? JSON.stringify({ statusCode: 0, stdout: "ok", stderr: "" }) : "provider text", { status })
const failure = async (fetchFn: typeof fetch): Promise<DriverError> => {
  const e = await freestyleExecStdin(fetchFn, "https://freestyle.test", "key", "vm-1", "true", null, 5_000).then(
    () => null,
    (err: unknown) => err
  )
  expect(e).toBeInstanceOf(DriverError)
  return e as DriverError
}

describe("Freestyle guest exec errors", () => {
  it("answers a 200 with the command's result", async () => {
    expect(await freestyleExecStdin(answering(200), "https://freestyle.test", "key", "vm-1", "true", null, 5_000)).toEqual({ exitCode: 0, stdout: "ok", stderr: "" })
  })

  it.each([409, 429, 500, 502, 503, 504])("keeps a %i retryable", async (status) => {
    expect(await failure(answering(status))).toMatchObject({ code: "cloud.provider.unavailable", final: false, message: `guest exec: ${status}` })
  })

  it("keeps no answer at all retryable", async () => {
    const unreachable: typeof fetch = async () => {
      throw new TypeError("network down")
    }
    expect(await failure(unreachable)).toMatchObject({ code: "cloud.provider.unavailable", final: false })
  })

  it("ends a deleted VM (404) as vm_missing", async () => {
    expect(await failure(answering(404))).toMatchObject({ code: "cloud.provider.vm_missing", final: true })
  })

  it.each([400, 401, 403, 422])("ends a refused request (%i)", async (status) => {
    expect(await failure(answering(status))).toMatchObject({ code: "cloud.provider.unavailable", final: true })
  })

  it.each([202, 302])("ends an answer that fails the same way on every try (%i)", async (status) => {
    expect(await failure(answering(status))).toMatchObject({ final: true })
  })

  it("never puts the provider's text in the error", async () => {
    expect((await failure(answering(503))).message).not.toContain("provider text")
  })

  it("bounds serialized bytes before decoding JSON and cancels the unread response", async () => {
    let cancelled = false
    const oversized: typeof fetch = async () => new Response(new ReadableStream<Uint8Array>({
      start(controller) { controller.enqueue(new Uint8Array(EXEC_RESPONSE_MAX_BYTES + 1)) },
      cancel() { cancelled = true }
    }))
    expect(await failure(oversized)).toMatchObject({ code: "cloud.exec.output_limit", final: true })
    expect(cancelled).toBe(true)
  })

  it("bounds chunk events even when the response emits no bytes", async () => {
    let pulled = 0
    let cancelled = false
    const tinyChunks: typeof fetch = async () => new Response(new ReadableStream<Uint8Array>({
      pull(controller) { pulled++; controller.enqueue(new Uint8Array()) },
      cancel() { cancelled = true }
    }, { highWaterMark: 0 }))
    expect(await failure(tinyChunks)).toMatchObject({ code: "cloud.exec.output_limit", final: true })
    expect(pulled).toBe(EXEC_RESPONSE_MAX_CHUNKS + 1)
    expect(cancelled).toBe(true)
  })

  it("decodes a bounded answer even when a UTF-8 character crosses chunk boundaries", async () => {
    const body = new TextEncoder().encode(JSON.stringify({ statusCode: 0, stdout: "café", stderr: "" }))
    const split = body.indexOf(0xc3) + 1
    const chunks: typeof fetch = async () => new Response(new ReadableStream<Uint8Array>({
      start(controller) {
        controller.enqueue(body.slice(0, split))
        controller.enqueue(body.slice(split))
        controller.close()
      }
    }))
    expect(await freestyleExecStdin(chunks, "https://freestyle.test", "key", "vm-1", "true", null, 5_000)).toEqual({ exitCode: 0, stdout: "café", stderr: "" })
  })

  // The provider's JSON of the largest answers the exec and file routes allow (cloud-machine-guest.ts),
  // sent in 64 KiB chunks: the bound is on that JSON, so output that escapes 6x (NUL and other control
  // bytes as \u0000) and an 8 MiB file read as base64 must both fit.
  const streamed = (json: string): typeof fetch => async () => {
    const body = new TextEncoder().encode(json)
    return new Response(new ReadableStream<Uint8Array>({
      start(controller) {
        for (let at = 0; at < body.byteLength; at += 64 * 1024) controller.enqueue(body.slice(at, at + 64 * 1024))
        controller.close()
      }
    }))
  }
  const NOTE = `\ncmux: output cut at ${OUTPUT_MAX_BYTES} bytes per stream\n`

  it("reads an exec whose two capped output streams are all NUL bytes (6x as JSON)", async () => {
    const stdout = "\0".repeat(OUTPUT_MAX_BYTES)
    const stderr = "\0".repeat(OUTPUT_MAX_BYTES) + NOTE
    const json = JSON.stringify({ statusCode: 0, stdout, stderr })
    expect(json.length).toBeGreaterThan(12 * OUTPUT_MAX_BYTES)
    expect(json.length).toBeLessThanOrEqual(EXEC_RESPONSE_MAX_BYTES)
    const r = await freestyleExecStdin(streamed(json), "https://freestyle.test", "key", "vm-1", "true", null, 5_000)
    expect(r.exitCode).toBe(0)
    expect(r.stdout === stdout && r.stderr === stderr).toBe(true)
  })

  it("reads the largest file read (FILE_MAX_BYTES as base64 in the file program's JSON)", async () => {
    const dataBase64 = "A".repeat(Math.ceil(FILE_MAX_BYTES / 3) * 4)
    const stdout = JSON.stringify({ path: "/home/cmux/big.bin", dataBase64, size: FILE_MAX_BYTES })
    const json = JSON.stringify({ statusCode: 0, stdout, stderr: "" })
    expect(json.length).toBeGreaterThan(FILE_MAX_BYTES)
    const r = await freestyleExecStdin(streamed(json), "https://freestyle.test", "key", "vm-1", "true", null, 5_000)
    expect(r.stdout === stdout).toBe(true)
  })

  it("reads the largest directory listing (DIR_MAX_BYTES of the file program's escaped JSON)", async () => {
    // json.dumps writes a name of control characters as \u0001 escapes; the provider escapes each backslash again.
    const name = "\\u0001".repeat(255)
    const entry = `{"name": "${name}", "kind": "file", "size": 0, "mode": 384, "modifiedAt": 1730000000000}`
    const count = Math.floor((DIR_MAX_BYTES - 16) / (entry.length + 2))
    const stdout = `{"entries": [${Array.from({ length: count }, () => entry).join(", ")}]}`
    expect(stdout.length).toBeLessThanOrEqual(DIR_MAX_BYTES)
    expect(stdout.length).toBeGreaterThan(DIR_MAX_BYTES - entry.length - 64)
    const json = JSON.stringify({ statusCode: 0, stdout, stderr: "" })
    const r = await freestyleExecStdin(streamed(json), "https://freestyle.test", "key", "vm-1", "true", null, 5_000)
    expect(r.stdout === stdout).toBe(true)
  })

  it("keeps the bound above every supported answer, with room for the envelope", () => {
    const envelope = 64 * 1024
    // fs/dir: the file program's listing is printable ASCII of at most DIR_MAX_BYTES, which the provider
    // escapes at most 6x. Without the byte bound, DIR_MAX_ENTRIES names of 255 control characters would not fit.
    expect(EXEC_RESPONSE_MAX_BYTES).toBeGreaterThanOrEqual(6 * DIR_MAX_BYTES + envelope)
    expect(DIR_MAX_ENTRIES * 255 * 6 * 2).toBeGreaterThan(EXEC_RESPONSE_MAX_BYTES)
    expect(EXEC_RESPONSE_MAX_BYTES).toBeGreaterThanOrEqual(2 * 6 * (OUTPUT_MAX_BYTES + 64) + envelope)
    expect(EXEC_RESPONSE_MAX_BYTES).toBeGreaterThanOrEqual(Math.ceil(FILE_MAX_BYTES / 3) * 4 + envelope)
    // A largest answer in 256-byte chunks still reads.
    expect(EXEC_RESPONSE_MAX_CHUNKS * 256).toBeGreaterThanOrEqual(EXEC_RESPONSE_MAX_BYTES)
  })
})
