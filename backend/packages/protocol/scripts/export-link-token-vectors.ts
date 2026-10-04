/**
 * Writes schemas/link-token/vectors.json (repo root): the shared vectors for link tokens
 * (plans/cmux-next/state-placement.md 5.8 item 6, decision LINK-TOKEN-FORMAT). The VM daemon's
 * verifier and the backend signer both run them. Each case stores the exact compact token, made
 * deterministically (Ed25519 signatures are deterministic) from FIXED TEST KEYS and fixed claims,
 * plus the expected verify result for each verifier input. The keys below are TEST ONLY and never
 * used by any deployment; the real signing keys are per-environment Worker secrets.
 *
 *   bun scripts/export-link-token-vectors.ts          write
 *   bun scripts/export-link-token-vectors.ts --check  fail when the checked-in file differs
 */
import { readFileSync, writeFileSync } from "node:fs"
import { fileURLToPath } from "node:url"
import { signLinkToken, verifyLinkToken, type LinkClaims } from "../../../apps/api/src/link-token.ts"

/** TEST ONLY Ed25519 keys (generated once for these vectors; never a real key). */
const TEST_KEYS = {
  "test-k1": { kty: "OKP", crv: "Ed25519", x: "tRRe5k08ymM7wh1Rh9EZkgf1p8UAskG2c_3dH0bYSGY", d: "HaAPeCaF6d-5Aqal74cq52xTcYQyBgDY0NgYKNhBIkc" },
  "test-k2": { kty: "OKP", crv: "Ed25519", x: "-IW5hjSjOqC3WBiaZ8uwfsemALBF4XaHTp8jxg8zcuY", d: "n5iGIhjSthiV5RHAf15uCfTJgZWQ5iEsiDWYYlqzG3g" }
} as const
const pub = (kid: keyof typeof TEST_KEYS) => ({ kty: "OKP", crv: "Ed25519", x: TEST_KEYS[kid].x, kid, alg: "EdDSA", use: "sig" })
const KEYSETS = { both: { "test-k1": pub("test-k1"), "test-k2": pub("test-k2") }, k2_only: { "test-k2": pub("test-k2") } } as const

const HOST = "host_h0000000000000000001"
const OTHER_HOST = "host_h0000000000000000002"
const IAT = 1790000000
const base = (jti: string): LinkClaims => ({
  iss: "cmux:cloud:test",
  aud: HOST,
  sub: "inst_i0000000000000000001",
  svc: ["daemon", "ssh"],
  epoch: 1,
  iat: IAT,
  exp: IAT + 300,
  jti,
  team: "team_t0000000000000000001"
})
const jti = (n: number) => `jti${String(n).padStart(19, "0")}`
type Expect = { ok: true } | { ok: false; error: string }
type Verify = { aud: string; epoch: number; now: number; keyset: keyof typeof KEYSETS; seen: Array<string>; expect: Expect }
const at = (over: Partial<Verify> & { expect: Expect }): Verify => ({ aud: HOST, epoch: 1, now: IAT + 10, keyset: "both", seen: [], ...over })

const specs: Array<{ name: string; kid: string; sign_with: keyof typeof TEST_KEYS; claims: LinkClaims; verify: Array<Verify>; note: string }> = [
  { name: "valid", kid: "test-k2", sign_with: "test-k2", claims: base(jti(1)), verify: [at({ expect: { ok: true } }), at({ keyset: "k2_only", expect: { ok: true } })], note: "Active kid, inside exp, this host and epoch." },
  { name: "expired", kid: "test-k2", sign_with: "test-k2", claims: base(jti(2)), verify: [at({ now: IAT + 301, expect: { ok: false, error: "expired" } })], note: "now past exp." },
  { name: "wrong_aud", kid: "test-k2", sign_with: "test-k2", claims: base(jti(3)), verify: [at({ aud: OTHER_HOST, expect: { ok: false, error: "aud" } })], note: "The token names another host." },
  { name: "wrong_epoch", kid: "test-k2", sign_with: "test-k2", claims: base(jti(4)), verify: [at({ epoch: 2, expect: { ok: false, error: "epoch" } })], note: "The VM was restored or re-bound (epoch 2)." },
  {
    name: "replay",
    kid: "test-k2",
    sign_with: "test-k2",
    claims: base(jti(5)),
    verify: [at({ expect: { ok: true } }), at({ seen: [jti(5)], expect: { ok: false, error: "replay" } })],
    note: "The same jti a second time within exp (the daemon keeps seen jtis until their exp)."
  },
  { name: "unknown_kid", kid: "test-k9", sign_with: "test-k2", claims: base(jti(6)), verify: [at({ expect: { ok: false, error: "unknown_kid" } })], note: "A kid that is not in the keyset." },
  {
    name: "rotated_kid",
    kid: "test-k1",
    sign_with: "test-k1",
    claims: base(jti(7)),
    verify: [at({ expect: { ok: true } }), at({ keyset: "k2_only", expect: { ok: false, error: "unknown_kid" } })],
    note: "Signed by the older kid: valid while the keyset still holds it, refused once rotation removed it."
  }
]

const cases = []
for (const s of specs) {
  const token = await signLinkToken(s.claims, s.kid, TEST_KEYS[s.sign_with])
  for (const v of s.verify) {
    const r = await verifyLinkToken(token, { aud: v.aud, epoch: v.epoch, now: v.now, keyset: KEYSETS[v.keyset], seen: new Set(v.seen) })
    const got: Expect = r.ok ? { ok: true } : { ok: false, error: r.error }
    if (JSON.stringify(got) !== JSON.stringify(v.expect)) throw new Error(`${s.name}: verifier says ${JSON.stringify(got)}, expected ${JSON.stringify(v.expect)}`)
  }
  cases.push({ name: s.name, note: s.note, kid: s.kid, sign_with: s.sign_with, claims: s.claims, token, verify: s.verify })
}

const doc = {
  $comment:
    "Link-token vectors (LINK-TOKEN-FORMAT, state-placement.md 5.8 item 6): compact JWS, EdDSA (Ed25519), header {alg: EdDSA, kid, typ: cmux-link+jwt}. test_keys are FIXED TEST KEYS ONLY, never a deployment key. Each token is byte-exact (deterministic signatures); verify lists the verifier inputs (now in seconds, keyset by name, seen = the replay set) and the expected result. Errors: expired, aud, epoch, replay, unknown_kid (also bad_signature, typ, lifetime, malformed). Generated by backend/packages/protocol/scripts/export-link-token-vectors.ts.",
  format: "cmux-link+jwt",
  version: 1,
  test_keys: TEST_KEYS,
  keysets: KEYSETS,
  cases
}

const out = fileURLToPath(new URL("../../../../schemas/link-token/vectors.json", import.meta.url))
const text = `${JSON.stringify(doc, null, 2)}\n`
if (process.argv.includes("--check")) {
  let current = ""
  try {
    current = readFileSync(out, "utf8")
  } catch {}
  if (current !== text) {
    console.error(`link-token vectors out of date: run bun scripts/export-link-token-vectors.ts (${out})`)
    process.exit(1)
  }
  console.log(`link-token vectors ok: ${cases.length} cases`)
} else {
  writeFileSync(out, text)
  console.log(`wrote ${out}: ${cases.length} cases`)
}
