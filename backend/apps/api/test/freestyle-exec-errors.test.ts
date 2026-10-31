import { describe, expect, it } from "vitest"
import { DriverError } from "../src/providers/contract.ts"
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
})
