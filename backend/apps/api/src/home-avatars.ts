import { createHash } from "node:crypto"
import type { Principal } from "@cmux/ownership"
import type { Env } from "./env.ts"

/**
 * Participant avatars on the Cloud owner (participant.avatar.set / participant.avatar.get, the same
 * ops and rules as the local owner's participant-avatars-v1). The account's UserDO keeps the
 * references, one per participant (the user and each of its Chiefs), in its own table outside the
 * op ledger (an avatar is profile data, never part of a conversation). The bytes are R2 objects in
 * HOME_ATTACHMENTS under `avatars/<owner_user>/<sha256>`: one blob per account and content, deleted
 * by the same UserDO when no participant of the account references it any more.
 */
export const MAX_AVATAR_BYTES = 1024 * 1024
export type AvatarMediaType = "image/png" | "image/jpeg" | "image/gif" | "image/webp"
export interface AvatarRef {
  readonly sha256: string
  readonly media_type: AvatarMediaType
  readonly bytes: number
}
export type AvatarRefusal = { readonly ok: false; readonly code: string; readonly message: string }

/** The media type from the bytes' signature (never the caller's claim), or null. */
export const sniffAvatar = (b: Uint8Array): AvatarMediaType | null => {
  const at = (i: number, sig: ReadonlyArray<number>) => sig.every((v, k) => b[i + k] === v)
  if (at(0, [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a])) return "image/png"
  if (at(0, [0xff, 0xd8, 0xff])) return "image/jpeg"
  if (at(0, [0x47, 0x49, 0x46, 0x38]) && (b[4] === 0x37 || b[4] === 0x39) && b[5] === 0x61) return "image/gif"
  if (at(0, [0x52, 0x49, 0x46, 0x46]) && at(8, [0x57, 0x45, 0x42, 0x50])) return "image/webp"
  return null
}

/** Checks decoded bytes: a known image signature and the size limit. */
export const checkAvatar = (b: Uint8Array): { ref: AvatarRef } | AvatarRefusal => {
  if (b.length === 0) return { ok: false, code: "avatar_invalid", message: "the avatar is empty" }
  if (b.length > MAX_AVATAR_BYTES) return { ok: false, code: "avatar_too_large", message: `the avatar is larger than ${MAX_AVATAR_BYTES} bytes` }
  const media_type = sniffAvatar(b)
  if (!media_type) return { ok: false, code: "avatar_invalid", message: "the avatar must be a PNG, JPEG, GIF or WebP image" }
  return { ref: { sha256: createHash("sha256").update(b).digest("hex"), media_type, bytes: b.length } }
}

export const avatarKey = (owner: string, sha256: string) => `avatars/${owner}/${sha256}`

/**
 * Who may set `participant`'s avatar in account `owner`: the person themselves (their session or a
 * person install, never a Chief token), or the owner for one of its active Chiefs. Nobody sets
 * another person's. (Cloud Chiefs have no self_edit list, so a Chief token sets none.)
 */
export const mayAvatarSet = (owner: string, principal: Principal, participant: string, isActiveChief: (id: string) => boolean): AvatarRefusal | null => {
  if (principal.user !== owner) return { ok: false, code: "forbidden", message: "an avatar is set from its own account" }
  if (principal.agent !== undefined) return { ok: false, code: "forbidden", message: "a Chief token cannot set an avatar" }
  if (participant === owner) return null
  if (participant.startsWith("agent_")) return isActiveChief(participant) ? null : { ok: false, code: "unknown_participant", message: "not an active Chief of this account" }
  return { ok: false, code: "forbidden", message: "nobody sets another person's avatar" }
}

/** The account's avatar references, in the UserDO's SQLite (one row per participant). */
export class AvatarRefs {
  constructor(private readonly sql: SqlStorage) {
    sql.exec(`CREATE TABLE IF NOT EXISTS avatar_ref (participant TEXT PRIMARY KEY, sha256 TEXT NOT NULL, media_type TEXT NOT NULL, bytes INTEGER NOT NULL)`)
  }

  get(participant: string): AvatarRef | null {
    const r = this.sql.exec<{ sha256: string; media_type: string; bytes: number }>(`SELECT sha256, media_type, bytes FROM avatar_ref WHERE participant = ?`, participant).toArray()[0]
    return r ? { sha256: r.sha256, media_type: r.media_type as AvatarMediaType, bytes: Number(r.bytes) } : null
  }

  /** Every participant with a reference. */
  participants(): ReadonlyArray<string> {
    return this.sql.exec<{ participant: string }>(`SELECT participant FROM avatar_ref`).toArray().map((r) => r.participant)
  }

  /** Sets or clears a reference; returns the blobs no participant references any more. */
  put(participant: string, ref: AvatarRef | null): ReadonlyArray<string> {
    const old = this.get(participant)
    if (ref) this.sql.exec(`INSERT OR REPLACE INTO avatar_ref (participant, sha256, media_type, bytes) VALUES (?, ?, ?, ?)`, participant, ref.sha256, ref.media_type, ref.bytes)
    else this.sql.exec(`DELETE FROM avatar_ref WHERE participant = ?`, participant)
    if (!old || old.sha256 === ref?.sha256) return []
    const still = this.sql.exec<{ n: number }>(`SELECT COUNT(*) AS n FROM avatar_ref WHERE sha256 = ?`, old.sha256).toArray()[0]
    return Number(still?.n ?? 0) === 0 ? [old.sha256] : []
  }
}

/** Base64 of a byte array (RPC answers carry the picture as text, as the local owner does). */
export const toBase64 = (b: Uint8Array) => Buffer.from(b).toString("base64")
export const fromBase64 = (s: string): Uint8Array | null => {
  if (!/^[A-Za-z0-9+/]*={0,2}$/.test(s)) return null
  return new Uint8Array(Buffer.from(s, "base64"))
}

export const avatarsConfigured = (env: Env) => env.HOME_ATTACHMENTS !== undefined
