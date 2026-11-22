import { createHash } from "node:crypto"

/**
 * Deterministic ids derived from the transaction tag, so the owner and every
 * mirror replaying the same event produce the same ids.
 */
export const idFactory = (tx: string) => {
  let n = 0
  return (prefix: string) =>
    `${prefix}_${createHash("sha256").update(`${tx}:${n++}`).digest("hex").slice(0, 20)}`
}
