/**
 * The `backend_only` part of backend/catalog/cloud-vectors.json (export-cloud-vectors.ts): requests a
 * correct client never sends, and the VM bind agent's POST /v1/cloud/bind (state-placement.md 5.8
 * item 2; not a catalog op). Synthetic data only.
 */
type Json = null | boolean | number | string | Array<Json> | { [k: string]: Json }
type Obj = { [k: string]: Json }

export const backendOnlyCases = (h: { TEAM: string; INSTALL_P: Obj; vm: (n: number) => string; host: (n: number) => string; readErr: (status: number, tag: string, code: string, message: string) => Obj }): Array<Obj> => {
  const { TEAM, INSTALL_P, vm, host, readErr } = h
  const backendOnly: Array<Obj> = []
backendOnly.push({
    name: "machine.link_token.key_refused",
    op: "cloud.machine.link_token",
    class: "mutation",
    principal: INSTALL_P,
    params: { host: host(1), services: ["daemon"] },
    request_idempotency_key: "client-key",
    responses: [{ http: { path: "/v1/ops", status: 400 }, body: { _tag: "BadRequest", code: "validation.invalid", message: "cloud.machine.link_token takes no idempotency_key" } }],
    note: "The request carried idempotency_key (request_idempotency_key): refused, so a stored answer can never hand a credential out twice."
  })

  // ---- bind (state-placement.md 5.8 item 2): POST /v1/cloud/bind with the VM's bind file, no bearer;
  // the one-time bind token is the credential. Not a catalog op (internal cloud.machine.bind).
  const BIND_PARAMS = { team: TEAM, machine: vm(4), bind_token: "bt_vector_one_time_token_000000000000000000", wg_public_key: "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=", daemon: { version: "0.40.0", capabilities: ["terminal", "files"] }, install_public_jwk: { kty: "EC", crv: "P-256", x: "x".repeat(43), y: "y".repeat(43) } }
  const VM_INSTALL = { id: "inst_v0000000000000000004", user: "user_u0000000000000000001", grant: "grant_v000000000000000004" }
  const BIND_P = { kind: "bind_token" }
  const KEYSET = { version: "0123456789abcdef", keys: { "vector-k1": { kty: "OKP", crv: "Ed25519", x: "11qYAYKxCrfVS_7TyWQHOg7hcvPapiMlrwIaaPcHURo", kid: "vector-k1", alg: "EdDSA", use: "sig" } } }
  const bindReply = (status: number, body: Obj): Obj => ({ http: { path: "/v1/cloud/bind", status }, body })
  backendOnly.push({
    name: "machine.connect_info.both_selectors",
    op: "cloud.machine.connect_info",
    class: "read",
    principal: INSTALL_P,
    params: { machine: vm(1), host: host(1) },
    responses: [readErr(400, "BadRequest", "validation.invalid", "give exactly one of machine and host")],
    note: "Exactly one of machine and host; the client refuses both or neither before sending, and the server refuses them too."
  })
  backendOnly.push(
    {
      name: "machine.bind",
      op: "cloud.machine.bind",
      principal: BIND_P,
      params: BIND_PARAMS,
      responses: [bindReply(200, { ok: true, value: { machine: vm(4), host: host(4), epoch: 1, keyset: KEYSET, install: VM_INSTALL } }), bindReply(403, { ok: false, error: { code: "auth.forbidden", message: "bind refused" } })],
      note: "responses[0]: the answer carries the public link keyset (at most 2 kids, no private part) and the VM install the server registered with install_public_jwk (kind vm, the machine creator, grant vm-self; the VM gets tokens through /v1/auth/challenge and /v1/auth/token), and the machine becomes running with its host (cloud.machine.upsert). responses[1]: a second bind with the spent token; any wrong, expired or unknown token is the same auth.forbidden."
    },
    {
      name: "machine.bind.invalid",
      op: "cloud.machine.bind",
      principal: BIND_P,
      params: { team: TEAM, machine: vm(4) },
      responses: [bindReply(400, { ok: false, error: { code: "validation.invalid", message: "invalid bind request" } })]
    }
  )
  return backendOnly
}
