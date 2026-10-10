import { env } from "cloudflare:workers"
import { runInDurableObject } from "cloudflare:test"
import { describe, expect, it } from "vitest"
import { kmsDecrypt, kmsEncrypt, sigv4, signingKey, type KmsConfig } from "../src/integrations/kms.ts"
import type { Http } from "../src/integrations/providers.ts"

const hex = (b: Uint8Array) => [...b].map((x) => x.toString(16).padStart(2, "0")).join("")

describe("AWS Signature Version 4 (published AWS example)", () => {
  // AWS General Reference, "Examples of the complete Signature Version 4 signing process" (IAM ListUsers, 2015-08-30).
  const secret = "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY"

  it("derives the documented signing key", async () => {
    expect(hex(await signingKey(secret, "20150830", "us-east-1", "iam"))).toBe("c4afb1cc5771d871763a393e44b703571b55cc28424d1a5e86da6ed3c154a4b9")
  })

  it("produces the documented canonical request hash and signature", async () => {
    const r = await sigv4({
      method: "GET",
      url: "https://iam.amazonaws.com/?Action=ListUsers&Version=2010-05-08",
      headers: { "content-type": "application/x-www-form-urlencoded; charset=utf-8", host: "iam.amazonaws.com", "x-amz-date": "20150830T123600Z" },
      body: "",
      region: "us-east-1",
      service: "iam",
      accessKeyId: "AKIDEXAMPLE",
      secretAccessKey: secret,
      amzDate: "20150830T123600Z"
    })
    expect(r.canonicalRequestHash).toBe("f536975d06c0309214f805bb90ccff089219ecd68b2577efef23edd43b7e1a59")
    expect(r.authorization).toBe(
      "AWS4-HMAC-SHA256 Credential=AKIDEXAMPLE/20150830/us-east-1/iam/aws4_request, SignedHeaders=content-type;host;x-amz-date, Signature=5d672d79c15b13162d9279b0855cfba6789a8edb4c82c400e06b5924a6f2b5d7"
    )
  })
})

/** A fake KMS: the blob carries the plaintext and the context; Decrypt refuses another context (as KMS does). */
export const fakeKms = () => {
  const calls: Array<{ target: string; authorization: string | null }> = []
  const http: Http = async (req) => {
    const target = (req.headers.get("x-amz-target") ?? "").replace("TrentService.", "")
    calls.push({ target, authorization: req.headers.get("authorization") })
    const body = (await req.json()) as { KeyId: string; Plaintext?: string; CiphertextBlob?: string; EncryptionContext: Record<string, string> }
    const ctx = JSON.stringify(Object.entries(body.EncryptionContext).sort())
    if (target === "Encrypt") return new Response(JSON.stringify({ CiphertextBlob: btoa(JSON.stringify({ k: body.KeyId, c: ctx, p: body.Plaintext })), KeyId: body.KeyId }), { status: 200 })
    const blob = JSON.parse(atob(body.CiphertextBlob ?? "")) as { k: string; c: string; p: string }
    if (blob.c !== ctx || blob.k !== body.KeyId) return new Response(JSON.stringify({ __type: "com.amazonaws.kms#InvalidCiphertextException" }), { status: 400 })
    return new Response(JSON.stringify({ Plaintext: blob.p, KeyId: body.KeyId }), { status: 200 })
  }
  return { http, calls }
}

describe("KMS client (fake KMS)", () => {
  const cfg: KmsConfig = { region: "us-east-1", keyArn: "arn:aws:kms:us-east-1:111122223333:key/test", accessKeyId: "AKIDTEST", secretAccessKey: "secret-test" }
  const context = { connection: "conn_a", owner: "team_a", provider: "gmail", generation: "1" }

  it("wraps and unwraps a data key, signs every request, and refuses another context", async () => {
    const kms = fakeKms()
    const dek = crypto.getRandomValues(new Uint8Array(32))
    const blob = await kmsEncrypt(cfg, kms.http, dek, context)
    expect(hex(await kmsDecrypt(cfg, kms.http, blob, context))).toBe(hex(dek))
    expect(kms.calls.every((c) => c.authorization?.startsWith("AWS4-HMAC-SHA256 Credential=AKIDTEST/") && c.authorization.includes("/us-east-1/kms/aws4_request"))).toBe(true)
    await expect(kmsDecrypt(cfg, kms.http, blob, { ...context, owner: "team_b" })).rejects.toMatchObject({ retryable: false })
  })

})

describe("credential sealing with KMS (fake KMS)", () => {
  const base = { INTEGRATIONS_KEK: btoa(String.fromCharCode(...crypto.getRandomValues(new Uint8Array(32)))) } as Record<string, string>
  const withKms = { ...base, INTEGRATIONS_KMS_KEY_ARN: "arn:aws:kms:us-east-1:111122223333:key/test", INTEGRATIONS_KMS_REGION: "us-east-1", INTEGRATIONS_KMS_ACCESS_KEY_ID: "AKIDTEST", INTEGRATIONS_KMS_SECRET_ACCESS_KEY: "secret-test" }
  const address = { connection: "conn_kms00000000000000000", owner: "team_a", provider: "gmail", generation: 3 }
  const credential = { kind: "oauth" as const, access_token: "ya29.kms-secret", refresh_token: "1//kms-refresh" }

  it("seals v2 under KMS with the encryption context, opens it, and refuses another address", async () => {
    const { sealCredential, openCredential } = await import("../src/integrations/credentials.ts")
    const kms = fakeKms()
    const sealed = await sealCredential(withKms as any, kms.http, address, credential)
    expect(sealed).toMatchObject({ v: 2, kid: "kms:arn:aws:kms:us-east-1:111122223333:key/test" })
    expect(JSON.stringify(sealed)).not.toContain("kms-secret")
    expect(await openCredential(withKms as any, kms.http, address, JSON.stringify(sealed))).toEqual(credential)
    await expect(openCredential(withKms as any, kms.http, { ...address, owner: "team_b" }, JSON.stringify(sealed))).rejects.toMatchObject({ code: "integration.unavailable" })
    await expect(openCredential(withKms as any, kms.http, { ...address, generation: 4 }, JSON.stringify(sealed))).rejects.toThrow()
    // A deployment without that KMS key cannot open it.
    await expect(openCredential(base as any, kms.http, address, JSON.stringify(sealed))).rejects.toThrow(/KMS key is not configured/)
  })

})

describe("KMS fallback is counted, marked and re-sealed", () => {
  const inDO = runInDurableObject as unknown as (stub: unknown, cb: (instance: any, state: DurableObjectState) => Promise<void>) => Promise<void>
  const testEnv = env as unknown as Record<string, any>
  const kmsEnv = { ...testEnv, INTEGRATIONS_KMS_KEY_ARN: "arn:aws:kms:us-east-1:111122223333:key/test", INTEGRATIONS_KMS_REGION: "us-east-1", INTEGRATIONS_KMS_ACCESS_KEY_ID: "AKIDTEST", INTEGRATIONS_KMS_SECRET_ACCESS_KEY: "secret-test" }
  const c = { id: "conn_fallback00000000000", owner: "team_fallback", provider: "gmail", status: "active" }
  const credential = { kind: "oauth" as const, access_token: "ya29.fb", refresh_token: "1//fb" }

  it("opens a previous key's rows in that key's region, and refuses an alias ARN as the key", async () => {
    const { sealCredential, openCredential, kmsConfig } = await import("../src/integrations/credentials.ts")
    const kms = fakeKms()
    const hosts: string[] = []
    const http: Http = async (req) => (hosts.push(new URL(req.url).host), kms.http(req))
    const address = { connection: c.id, owner: c.owner, provider: c.provider, generation: 1 }
    const oldArn = "arn:aws:kms:eu-west-1:111122223333:key/old"
    const sealed = JSON.stringify(await sealCredential({ ...kmsEnv, INTEGRATIONS_KMS_KEY_ARN: oldArn, INTEGRATIONS_KMS_REGION: "eu-west-1" } as any, http, address, credential))
    expect(await openCredential({ ...kmsEnv, INTEGRATIONS_KMS_PREVIOUS_KEY_ARNS: oldArn } as any, http, address, sealed)).toEqual(credential)
    expect(hosts.at(-1)).toBe("kms.eu-west-1.amazonaws.com")
    expect(kmsConfig({ ...kmsEnv, INTEGRATIONS_KMS_KEY_ARN: "arn:aws:kms:us-east-1:111122223333:alias/cmux" } as any)).toBeUndefined()
    expect(kmsConfig({ ...kmsEnv, INTEGRATIONS_KMS_KEY_ARN: "alias/cmux" } as any)).toBeUndefined()
    expect(kmsConfig(kmsEnv as any)?.keyArn).toBe(kmsEnv.INTEGRATIONS_KMS_KEY_ARN)
  })

})
