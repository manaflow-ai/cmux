import { describe, expect, it } from "vitest"
import { attachmentLine, formatMessage } from "../src/chief-brain/brain-text.ts"
import { wantedFiles } from "../src/chief-brain-cc/attachments.ts"

/**
 * How a Chief reads a message's attachment (brain-text.ts): its name, type, pixels and size, and on the Claude
 * Code route the path of its file in the turn machine (chief-brain-cc/attachments.ts writes it there), so the
 * Chief opens a pasted screenshot with its Read tool.
 */
const H = "0123456789abcdef".repeat(4)
const head = { id: "conv_x", kind: "chief", title: "", participants: [{ id: "user_1", display_name: "Lawrence", kind: "human" }] } as never
const msg = (parts: Array<unknown>) => ({ id: "msg_1", seq: 1, author: "user_1", parts }) as never
const png = { type: "attachment", hash: H, name: "Screenshot 9.47.59.png", mime_type: "image/png", byte_count: 2_100_000, width: 2880, height: 1800 }

describe("Chief attachment lines", () => {
  it("names a pasted PNG's file in the turn machine, with its type, pixels and size", () => {
    expect(formatMessage(head, msg([{ type: "text", text: "what is wrong here?" }, png]), { files: true })).toBe(
      `[chief · chief · Lawrence] what is wrong here?\n[attachment: Screenshot 9.47.59.png, image/png 2880x1800 2.0 MB, file /home/chief/work/.attachments/${H}.png]`
    )
  })

  it("says what the file is without a path on a route with no turn machine", () => {
    expect(formatMessage(head, msg([png]))).toBe("[chief · chief · Lawrence] [attachment: Screenshot 9.47.59.png, image/png 2880x1800 2.0 MB]")
  })

  it("keeps originals alongside model-friendly previews and posters", () => {
    const preview = { hash: "c".repeat(64), mime_type: "image/jpeg", byte_count: 400_000 }
    expect(attachmentLine({ ...png, mime_type: "image/heic", name: "IMG_1.heic", preview }, true)).toBe(`[attachment: IMG_1.heic, image/heic 2880x1800 2.0 MB, preview image /home/chief/work/.attachments/${H}.preview.jpg, file /home/chief/work/.attachments/${H}.heic]`)
    expect(attachmentLine({ ...png, byte_count: 40_000_000, preview }, true)).toContain(`preview image /home/chief/work/.attachments/${H}.preview.jpg, file /home/chief/work/.attachments/${H}.png]`)
    expect(attachmentLine({ ...png, byte_count: 40_000_000 }, true)).toContain(`file /home/chief/work/.attachments/${H}.png]`)
    expect(attachmentLine({ hash: H, name: "run.mp4", mime_type: "video/mp4", byte_count: 9_000_000, width: 1920, height: 1080, duration_ms: 12_000, poster: preview }, true)).toBe(
      `[attachment: run.mp4, video/mp4 1920x1080 12 s 8.6 MB, poster image /home/chief/work/.attachments/${H}.poster.jpg, file /home/chief/work/.attachments/${H}.mp4]`
    )
    expect(attachmentLine({ hash: H, name: "spec.pdf", mime_type: "application/pdf", byte_count: 90_000 }, true)).toBe(`[attachment: spec.pdf, application/pdf 88 KB, file /home/chief/work/.attachments/${H}.pdf]`)
  })

  it("names large originals of any type without allocating their bytes", () => {
    for (const mime of ["application/zip", "application/pdf", "audio/wav", "video/mp4", "application/x-custom"]) {
      const line = attachmentLine({ hash: H, mime_type: mime, byte_count: 10 * 1024 ** 3 }, true)
      expect(wantedFiles(line)).toEqual([expect.objectContaining({ hash: H })])
      expect(line).not.toContain("unavailable")
    }
  })

  it("never names a path for a part without a well-formed hash, and keeps a name from closing the bracket", () => {
    expect(attachmentLine({ ...png, hash: "../../etc/passwd" }, true)).toContain("file unavailable]")
    expect(attachmentLine({ ...png, name: "a]b\nc.png" }, false)).toBe("[attachment: a b c.png, image/png 2880x1800 2.0 MB]")
  })

  it("stages the files a turn's input names, newest first, each once", () => {
    const a = `/home/chief/work/.attachments/${"a".repeat(64)}.png`
    const b = `/home/chief/work/.attachments/${"b".repeat(64)}.preview.jpg`
    expect(wantedFiles(`old ${a} then ${b} and again ${a}`)).toEqual([
      { hash: "a".repeat(64), path: a },
      { hash: "b".repeat(64), variant: "preview", path: b }
    ])
    expect(wantedFiles("/home/chief/work/.attachments/../x.png ~/work/.attachments/zz.png")).toEqual([])
  })
})
