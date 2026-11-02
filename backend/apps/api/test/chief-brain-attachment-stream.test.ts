import { createHash } from "node:crypto"
import { afterEach, describe, expect, it, vi } from "vitest"
import type { Env } from "../src/env.ts"
import { stageAttachments } from "../src/chief-brain-cc/attachments.ts"

const directory = "/home/chief/work/.attachments"
const sourceChunk = new Uint8Array(1024 * 1024 + 7).fill(37)
const hashOf = (chunks: number) => {
  const hash = createHash("sha256")
  for (let n = 0; n < chunks; n++) hash.update(sourceChunk)
  return hash.digest("hex")
}

afterEach(() => vi.unstubAllGlobals())

type StreamOptions = { wrongHash?: boolean; sizeDelta?: number; failWrite?: boolean; corruptVm?: boolean; readFailure?: boolean; forbidden?: boolean; variant?: boolean }
const fixture = (chunks: number, options: StreamOptions = {}) => {
  const hash = options.wrongHash ? "a".repeat(64) : hashOf(chunks)
  const originalHash = options.variant ? "b".repeat(64) : hash
  const path = `${directory}/${originalHash}${options.variant ? ".preview.jpg" : ".bin"}`
  let pulls = 0
  const cancel = vi.fn()
  const stream = new ReadableStream<Uint8Array>({
    pull(controller) {
      if (options.readFailure && pulls === 1) return controller.error(new Error("read failed"))
      if (pulls === chunks) return controller.close()
      pulls++
      controller.enqueue(sourceChunk)
    },
    cancel
  }, { highWaterMark: 0 })
  const record = {
    object_key: "conversation/file", byte_count: chunks * sourceChunk.length + (options.sizeDelta ?? 0), etag: "etag-original",
    mime_type: options.variant ? "image/png" : "application/octet-stream",
    ...(options.variant ? { preview: { hash, byte_count: chunks * sourceChunk.length, etag: "etag-preview" } } : {})
  }
  const download = vi.fn(async () => options.forbidden ? "forbidden" : { record })
  const get = vi.fn(async () => ({ body: stream, arrayBuffer: () => { throw new Error("must stream") } }))
  const env = {
    CHIEF_CC_FREESTYLE_API_URL: "https://freestyle.test", CHIEF_CC_FREESTYLE_API_KEY: "test-key",
    HOME_ATTACHMENTS: { get }, CONVERSATION_DO: { idFromName: (id: string) => id, get: () => ({ downloadAccess: download }) }
  } as unknown as Env
  const commands: Array<string> = []
  let bytes = 0
  let largestWrite = 0
  const received = createHash("sha256")
  vi.stubGlobal("fetch", async (url: string, init: RequestInit) => {
    expect(url).toBe("https://freestyle.test/v5/vms/test-vm/exec-await")
    const body = JSON.parse(init.body as string) as { command: string; stdin?: string }
    commands.push(body.command)
    if (body.stdin) {
      const chunk = Buffer.from(body.stdin, "base64")
      // Backpressure: the next R2 chunk is not requested before writing the current one.
      expect(pulls).toBe(Math.floor(bytes / sourceChunk.length) + 1)
      bytes += chunk.length
      largestWrite = Math.max(largestWrite, chunk.length)
      received.update(chunk)
      return Response.json({ statusCode: options.failWrite ? 1 : 0, stdout: "" })
    }
    if (body.command.includes("mv -f")) {
      const actual = received.digest("hex")
      expect(actual).toBe(hash)
      return Response.json({ statusCode: options.corruptVm ? 1 : 0, stdout: options.corruptVm ? "" : "ok\n" })
    }
    return Response.json({ statusCode: 0, stdout: "" })
  })
  return { run: () => stageAttachments(env, "test-vm", "agent_test", "user_test", "conv_test", path), path, commands, cancel, get, download, bytes: () => bytes, largestWrite: () => largestWrite }
}

describe("Chief original attachment streaming", () => {
  it("streams an original beyond both old byte limits, without buffering it or exceeding exec stdin", async () => {
    const f = fixture(49)
    expect(await f.run()).toEqual({ written: 1, bytes: 49 * sourceChunk.length, missing: [] })
    expect(f.bytes()).toBe(49 * sourceChunk.length)
    expect(f.largestWrite()).toBeLessThanOrEqual(768 * 1024)
    expect(f.commands.at(-1)).toContain(`mv -f`)
    expect(f.commands.at(-1)).toContain(` ${f.path} && echo ok`)
    expect(f.get).toHaveBeenCalledWith("conversation/file", { onlyIf: { etagMatches: "etag-original" } })
    expect(f.download).toHaveBeenCalledWith("conv_test", "agent_test", { hash: hashOf(49) })
  })

  it.each([
    [{ wrongHash: true }, "hash"],
    [{ sizeDelta: 1 }, "size"],
    [{ sizeDelta: -1 }, "size"],
    [{ readFailure: true }, "transfer"],
    [{ failWrite: true }, "write"],
    [{ corruptVm: true }, "write"]
  ] as Array<[StreamOptions, string]>)("cleans partial files on failed integrity or transport (%j)", async (options, reason) => {
    const f = fixture(2, options)
    const result = await f.run()
    expect(result.written).toBe(0)
    expect(result.bytes).toBe(0)
    expect(result.missing).toEqual([{ path: f.path, why: expect.stringContaining(reason) }])
    expect(f.commands.at(-1)).toMatch(/^rm -f .*\.part$/)
    if (options.failWrite || options.sizeDelta === -1) expect(f.cancel).toHaveBeenCalledOnce()
    if (!options.corruptVm) expect(f.commands.some((command) => command.includes("mv -f"))).toBe(false)
  })

  it("uses and verifies the derived object's own hash and etag", async () => {
    const f = fixture(1, { variant: true })
    expect(await f.run()).toEqual({ written: 1, bytes: sourceChunk.length, missing: [] })
    expect(f.get).toHaveBeenCalledWith("conversation/file.preview", { onlyIf: { etagMatches: "etag-preview" } })
  })

  it("refuses unauthorized objects before opening the stream or writing to a machine", async () => {
    const f = fixture(1, { forbidden: true })
    expect((await f.run()).missing).toEqual([{ path: f.path, why: "not a participant" }])
    expect(f.get).not.toHaveBeenCalled()
    expect(f.commands).toEqual([])
  })
})
