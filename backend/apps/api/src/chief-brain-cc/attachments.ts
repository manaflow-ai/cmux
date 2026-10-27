import { createHash } from "node:crypto"
import { conversation as homeConversation } from "@cmux/home-core"
import type { Env } from "../env.ts"
import type { DownloadAccess } from "../conversation-do.ts"
import { chiefPrincipal } from "../chief-brain/brain-io.ts"
import { ATTACHMENT_DIR, ATTACHMENT_PATH } from "../chief-brain/brain-text.ts"
import { execRoot } from "./vm.ts"

/**
 * The files a Claude Code turn reads (turn.ts): each attachment path its input names (brain-text.ts
 * attachmentLine, `/home/chief/work/.attachments/<hash>[.preview|.poster].<ext>`) is fetched from the Home
 * attachment bucket and written into the turn machine before Claude Code starts, so the Chief opens a pasted
 * screenshot with its Read tool as any file.
 *
 * Access is the Chief's own: the conversation's downloadAccess as the Chief's actor (a current participant,
 * the record usable above its history floor), the same check a download URL minted for the Chief passes; a
 * hash of another conversation is not found there. The bytes go only to the machine (exec stdin, in chunks
 * under its 1 MiB limit); they are never logged, and the machine is deleted after the turn.
 */
type Access = { downloadAccess(entity: string, actor: string, by: { hash: string }): Promise<DownloadAccess | "forbidden"> }

/** At most this many files a turn (the newest named). */
export const MAX_FILES = 12
/** One exec's stdin (Freestyle allows 1 MiB decoded). */
const CHUNK = 768 * 1024

export interface Wanted {
  readonly hash: string
  readonly variant?: "preview" | "poster"
  readonly path: string
}

/** The attachment files `text` names, the newest (last named) first, each once, at most MAX_FILES. */
export const wantedFiles = (text: string): Array<Wanted> => {
  const seen = new Map<string, Wanted>()
  for (const m of text.matchAll(ATTACHMENT_PATH)) {
    const path = m[0]
    seen.delete(path)
    seen.set(path, { hash: m[1]!, ...(m[2] ? { variant: m[2] as "preview" | "poster" } : {}), path })
  }
  return [...seen.values()].reverse().slice(0, MAX_FILES)
}

export interface Staged {
  readonly written: number
  readonly bytes: number
  /** Paths not written, with why (no bytes: they are shown to the Chief in its input). */
  readonly missing: ReadonlyArray<{ path: string; why: string }>
}

type FileStream = { readonly body: ReadableStream<Uint8Array>; readonly size: number; readonly hash: string }

/** Authorize and open one stored object without buffering its bytes. */
const fetchFile = async (env: Env, access: Access, conversation: string, actor: string, w: Wanted): Promise<FileStream | string> => {
  if (!env.HOME_ATTACHMENTS) return "attachments are not configured"
  const got = await access.downloadAccess(conversation, actor, { hash: w.hash }).catch(() => null)
  if (got === "forbidden") return "not a participant"
  if (!got) return "not found in this conversation"
  const rec = got.record
  let key = rec.object_key
  let etag = rec.etag
  let size = rec.byte_count
  let hash = w.hash
  if (w.variant) {
    const image = homeConversation.derivedVariantOf(rec.mime_type) === w.variant ? rec[w.variant] : undefined
    if (!image) return `no ${w.variant}`
    key = homeConversation.attachmentDerivedKey(rec.object_key, w.variant)
    etag = image.etag
    size = image.byte_count
    hash = image.hash
  }
  const obj = await env.HOME_ATTACHMENTS.get(key, etag ? { onlyIf: { etagMatches: etag } } : {})
  if (!obj || !("body" in obj)) return "the stored file is gone"
  return { body: obj.body, size, hash }
}

/** Stream into a private temporary file. Publish only after the streamed length and hash match the record. */
const writeFile = async (env: Env, vm: string, path: string, file: FileStream): Promise<string | null> => {
  const name = path.slice(ATTACHMENT_DIR.length + 1)
  const reader = file.body.getReader()
  if (!/^[0-9a-f]{64}(\.(preview|poster))?\.[a-z0-9]{1,8}$/.test(name)) {
    await reader.cancel().catch(() => undefined)
    reader.releaseLock()
    return "invalid attachment path"
  }
  const part = `${ATTACHMENT_DIR}/.${name}.${crypto.randomUUID()}.part`
  const head = `install -d -o chief -g chief -m 700 ${ATTACHMENT_DIR} && umask 077 && cat > ${part}`
  const hash = createHash("sha256")
  let count = 0
  let started = false
  let published = false
  try {
    for (;;) {
      const { done, value } = await reader.read()
      if (done) break
      if (count + value.byteLength > file.size) return "the stored file does not match its size"
      hash.update(value)
      // R2 read boundaries need not match the provider's stdin bound.
      for (let at = 0; at < value.byteLength; at += CHUNK) {
        const command = started ? `cat >> ${part}` : head
        started = true
        const result = await execRoot(env, vm, command, value.subarray(at, at + CHUNK), 30_000)
        if (result.exit !== 0) return "the write to the machine failed"
      }
      count += value.byteLength
    }
    if (count !== file.size || !started) return "the stored file does not match its size"
    const digest = hash.digest("hex")
    if (digest !== file.hash) return "the stored file does not match its hash"
    const done = await execRoot(env, vm, `chown chief:chief ${part} && chmod 600 ${part} && mv -f ${part} ${path} && echo ok`, null, 30_000)
    published = done.exit === 0 && done.stdout.includes("ok")
    return published ? null : "the write to the machine failed"
  } catch {
    return "the transfer to the machine failed"
  } finally {
    await reader.cancel().catch(() => undefined)
    reader.releaseLock()
    if (started && !published) await execRoot(env, vm, `rm -f ${part}`, null, 15_000).catch(() => undefined)
  }
}

/** Stages every attachment file `text` names into the turn machine `vm`; a file that cannot be had is skipped with its reason. */
export const stageAttachments = async (env: Env, vm: string, agent: string, owner: string, conversation: string, text: string): Promise<Staged> => {
  const wanted = wantedFiles(text)
  const missing: Array<{ path: string; why: string }> = []
  if (wanted.length === 0) return { written: 0, bytes: 0, missing }
  const actor = homeConversation.actorOf(chiefPrincipal(agent, owner))
  if (!actor) return { written: 0, bytes: 0, missing: wanted.map((w) => ({ path: w.path, why: "no actor" })) }
  const access = env.CONVERSATION_DO.get(env.CONVERSATION_DO.idFromName(conversation)) as unknown as Access
  let written = 0
  let bytes = 0
  for (const w of wanted) {
    const got = await fetchFile(env, access, conversation, actor, w).catch(() => "the fetch failed")
    if (typeof got === "string") {
      missing.push({ path: w.path, why: got })
      continue
    }
    const failure = await writeFile(env, vm, w.path, got)
    if (failure) missing.push({ path: w.path, why: failure })
    else [written++, (bytes += got.size)]
  }
  return { written, bytes, missing }
}
