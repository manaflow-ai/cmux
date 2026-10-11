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
import { rawSignLinkToken } from "../../../apps/api/test/link-vector-sign.ts"
import { LINK_TOKEN_TYP, signLinkToken, verifyLinkToken, type LinkClaims } from "../../../apps/api/src/link-token.ts"

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

type Make = "tamper_signature" | "alg_none" | "wrong_typ" | "raw_sign"
const specs: Array<{ name: string; kid: string; sign_with: keyof typeof TEST_KEYS; claims: LinkClaims; verify: Array<Verify>; note: string; make?: Make }> = [
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
  },
  { name: "exp_boundary", kid: "test-k2", sign_with: "test-k2", claims: base(jti(8)), verify: [at({ now: IAT + 299, expect: { ok: true } }), at({ now: IAT + 300, expect: { ok: false, error: "expired" } })], note: "now = exp is expired (valid only while now < exp)." },
  { name: "bad_signature", kid: "test-k2", sign_with: "test-k2", claims: base(jti(9)), make: "tamper_signature", verify: [at({ expect: { ok: false, error: "bad_signature" } })], note: "One signature byte changed: a verifier that skips the signature passes every other case but not this one." },
  { name: "alg_none", kid: "test-k2", sign_with: "test-k2", claims: base(jti(10)), make: "alg_none", verify: [at({ expect: { ok: false, error: "malformed" } })], note: "Header alg none and an empty signature: any alg other than EdDSA is malformed." },
  { name: "wrong_typ", kid: "test-k2", sign_with: "test-k2", claims: base(jti(11)), make: "wrong_typ", verify: [at({ expect: { ok: false, error: "typ" } })], note: "Correctly signed, but the header typ is JWT, not cmux-link+jwt." },
  { name: "lifetime", kid: "test-k2", sign_with: "test-k2", claims: { ...base(jti(12)), exp: IAT + 301 }, make: "raw_sign", verify: [at({ expect: { ok: false, error: "lifetime" } })], note: "Correctly signed, but exp - iat = 301 s, above the 300 s maximum." }
]

const b64u = (s: string) => btoa(s).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "")
const rawSign = (c: LinkClaims, kid: string, typ: string) => rawSignLinkToken(c, kid, typ, TEST_KEYS["test-k2"])
const make = async (s: (typeof specs)[number]): Promise<string> => {
  if (s.make === "raw_sign") return rawSign(s.claims, s.kid, LINK_TOKEN_TYP)
  if (s.make === "wrong_typ") return rawSign(s.claims, s.kid, "JWT")
  const token = await signLinkToken(s.claims, s.kid, TEST_KEYS[s.sign_with])
  const [h, p, sig] = token.split(".") as [string, string, string]
  if (s.make === "alg_none") return `${b64u(JSON.stringify({ alg: "none", kid: s.kid, typ: LINK_TOKEN_TYP }))}.${p}.`
  if (s.make === "tamper_signature") {
    const bytes = Uint8Array.from(atob(sig.replace(/-/g, "+").replace(/_/g, "/")), (ch) => ch.charCodeAt(0))
    bytes[0] = bytes[0]! ^ 0x01
    return `${h}.${p}.${b64u(String.fromCharCode(...bytes))}`
  }
  return token
}

const cases = []
for (const s of specs) {
  const token = await make(s)
  for (const v of s.verify) {
    const r = await verifyLinkToken(token, { aud: v.aud, epoch: v.epoch, now: v.now, keyset: KEYSETS[v.keyset], seen: new Set(v.seen) })
    const got: Expect = r.ok ? { ok: true } : { ok: false, error: r.error }
    if (JSON.stringify(got) !== JSON.stringify(v.expect)) throw new Error(`${s.name}: verifier says ${JSON.stringify(got)}, expected ${JSON.stringify(v.expect)}`)
  }
  cases.push({ name: s.name, note: s.note, kid: s.kid, sign_with: s.sign_with, make: s.make ?? null, claims: s.claims, token, verify: s.verify })
}

const doc = {
  $comment:
    "Link-token vectors (LINK-TOKEN-FORMAT, state-placement.md 5.8 item 6): compact JWS, EdDSA (Ed25519), header {alg: EdDSA, kid, typ: cmux-link+jwt}. test_keys are FIXED TEST KEYS ONLY, never a deployment key. Each token is byte-exact (deterministic signatures); verify lists the verifier inputs (now in seconds, keyset by name, seen = the replay set) and the expected result. Errors: expired, aud, epoch, replay, unknown_kid, bad_signature, typ, lifetime, malformed. make is null when the token is the backend signer's output (a signer test re-signs those byte-equal); otherwise it names how the refusal token was built (tamper_signature, alg_none, wrong_typ, raw_sign) and only the verify results apply. Generated by backend/packages/protocol/scripts/export-link-token-vectors.ts.",
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
