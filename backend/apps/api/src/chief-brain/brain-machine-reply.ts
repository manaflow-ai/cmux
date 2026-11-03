/** One message stays under the conversation's 64 KiB text bound; the reply itself has no cap. */
const CHUNK_BYTES = 60 * 1024

/** The UTF-16 offset is journaled after each accepted message, without splitting a Unicode scalar. */
export const machineReplyChunk = (reply: string, offset: number): { text: string; next: number; done: boolean } => {
  if (!Number.isSafeInteger(offset) || offset < 0 || offset >= reply.length) throw new Error("chief.machine.reply_cursor_invalid")
  let next = offset, bytes = 0
  while (next < reply.length) {
    const point = reply.codePointAt(next)!
    const width = point < 0x80 ? 1 : point < 0x800 ? 2 : point < 0x10000 ? 3 : 4
    if (bytes + width > CHUNK_BYTES) break
    bytes += width
    next += point > 0xffff ? 2 : 1
  }
  return { text: reply.slice(offset, next), next, done: next === reply.length }
}
