import { readdirSync, readFileSync } from "node:fs"
import { join } from "node:path"
import { fileURLToPath } from "node:url"
import { Exit, Schema } from "effect"
import { describe, expect, it } from "vitest"
import {
  cloudOpByName,
  decodeFileChunk,
  decodeMobileFrame,
  decodeMobileJson,
  decodeRdStreamFrame,
  decodeRecord,
  decodeTerminalInput,
  decodeTerminalOutput,
  encodeFileChunk,
  encodeMobileFrame,
  encodeMobileJson,
  encodeRdStreamFrame,
  encodeRecord,
  encodeTerminalInput,
  encodeTerminalOutput,
  flagNames,
  flagsOf,
  frameRecord,
  jsonRecord,
  mobileCatalog,
  mobileFrameTypes,
  mobileMessageByName,
  mobileMessageOf,
  RecordDeframer,
  RecordError,
  recordCredit,
  creditRecord,
  recordJson,
  type RecordFlagName,
  type StreamRecord
} from "../src/index.ts"
import { SchemaSet } from "./json-schema-subset.ts"

// schemas/mobile-rpc is the shared contract with Swift CmuxMobileWire (a0-rpc.md). Every fixture
// round-trips through the TS codec, validates against the JSON Schemas, and existing cloud ops'
// params also validate against their Effect Schemas.
const ROOT = fileURLToPath(new URL("../../../../schemas/mobile-rpc/", import.meta.url))
const read = <T>(rel: string): T => JSON.parse(readFileSync(join(ROOT, rel), "utf8")) as T
const schemas = new SchemaSet()
const envelope = join(ROOT, "envelope.schema.json")

interface Case { readonly message?: string; readonly phase?: "request" | "result" | "opened" | "state" | "reject" | "refused"; readonly frame: Record<string, unknown> }
const familyFiles = readdirSync(join(ROOT, "fixtures")).filter((f) => !["frames.json", "binary.json"].includes(f))
const families = familyFiles.map((f) => read<{ family: string; cases: Array<Case> }>(`fixtures/${f}`))

const hex = (b: Uint8Array) => Buffer.from(b).toString("hex")
const bytes = (h: string) => new Uint8Array(Buffer.from(h, "hex"))

describe("cmux.mobile/1 catalog", () => {
  it("equals schemas/mobile-rpc/catalog.json", () => {
    const json = read<{ proto: string; version: number; families: unknown }>("catalog.json")
    expect({ proto: json.proto, version: json.version, families: json.families }).toEqual(JSON.parse(JSON.stringify(mobileCatalog)))
  })

  it("names are unique and every family has a schema file and a fixture file", () => {
    const names = mobileCatalog.families.flatMap((f) => f.messages.map((m) => m.name))
    expect(new Set(names).size).toBe(names.length)
    for (const f of mobileCatalog.families) {
      expect(familyFiles).toContain(`${f.name}.json`)
      expect(schemas.has(join(ROOT, `families/${f.name}.schema.json`), "#/$defs")).toBe(true)
    }
  })

  it("every message has a fixture (records in binary.json) and a params schema", () => {
    const covered = new Set(families.flatMap((f) => f.cases.map((c) => c.message)))
    for (const r of read<{ records: Array<{ message?: string }> }>("fixtures/binary.json").records) covered.add(r.message)
    for (const f of mobileCatalog.families) {
      for (const m of f.messages) {
        expect([m.name, covered.has(m.name)]).toEqual([m.name, true])
        if (m.kind !== "record") expect([m.name, schemas.has(join(ROOT, `families/${f.name}.schema.json`), `#/$defs/${m.name}`)]).toEqual([m.name, true])
      }
    }
  })

  it("existing ops are in the cloud catalog with the same class", () => {
    for (const f of mobileCatalog.families) {
      for (const m of f.messages.filter((m) => "existing" in m && m.existing)) {
        const cloud = cloudOpByName.get(m.name)
        expect([m.name, cloud !== undefined]).toEqual([m.name, true])
        if (m.kind === "read") expect(cloud?.class).toBe("read")
        if (m.kind === "op") expect(cloud?.class).toBe("mutation")
      }
    }
  })
})

describe("cmux.mobile/1 JSON frames", () => {
  it("every frame type has an example in frames.json", () => {
    const frames = read<{ frames: Array<{ t: string }> }>("fixtures/frames.json").frames
    expect(new Set(frames.map((f) => f.t))).toEqual(new Set(mobileFrameTypes))
  })

  it("frames.json round-trips and validates against the envelope schema", () => {
    for (const frame of read<{ frames: Array<Record<string, unknown>> }>("fixtures/frames.json").frames) {
      expect(encodeMobileFrame(decodeMobileFrame(frame))).toEqual(frame)
      expect([frame.t, schemas.validate(envelope, "", frame)]).toEqual([frame.t, []])
    }
  })

  it("refuses unknown frame types and malformed frames with the shared error codes", () => {
    expect(() => decodeMobileFrame({ t: "x-new" })).toThrow(expect.objectContaining({ code: "proto.unknown_frame" }))
    expect(() => decodeMobileFrame({ t: "op", op: "host.wake" })).toThrow(expect.objectContaining({ code: "validation.invalid" }))
  })

  for (const fam of families) {
    it(`${fam.family} fixtures round-trip, name their message and validate`, () => {
      const schemaFile = join(ROOT, `families/${fam.family}.schema.json`)
      for (const c of fam.cases) {
        const label = `${fam.family}:${c.message ?? "state"}:${c.phase ?? "request"}`
        expect([label, encodeMobileJson(decodeMobileJson(c.frame))]).toEqual([label, c.frame])
        const def = c.message ? mobileMessageByName.get(c.message) : undefined
        if (c.message) expect([label, def?.family]).toEqual([label, fam.family])
        const errs = (pointer: string, value: unknown) => schemas.validate(schemaFile, pointer, value)
        const phase = c.phase ?? "request"
        if (phase === "state") {
          expect(c.frame.t).toBe("snapshot")
          expect([label, errs(`#/$defs/${fam.family}:state`, c.frame.state)]).toEqual([label, []])
        } else if (phase === "result") {
          expect(["read.result", "result"]).toContain(c.frame.t)
          expect([label, errs(`#/$defs/${c.message}:result`, c.frame.value)]).toEqual([label, []])
        } else if (phase === "opened") {
          expect(c.frame.t).toBe("channel.opened")
          expect([label, errs(`#/$defs/${c.message}:opened`, c.frame.params)]).toEqual([label, []])
        } else if (phase === "reject") {
          expect(c.frame.t).toBe("reject")
          expect(def?.errors ?? []).toContain(c.frame.code)
        } else if (phase === "refused") {
          // Channel refusal is an envelope outcome, so it has no catalog
          // message name to return from mobileMessageOf.
          expect(c.frame.t).toBe("channel.refused")
        } else if (def?.kind === "message") {
          expect([label, errs(`#/$defs/${c.message}`, c.frame)]).toEqual([label, []])
        } else {
          const frame = decodeMobileFrame(c.frame)
          expect([label, mobileMessageOf(frame)]).toEqual([label, c.message])
          const expected = { op: "op", read: "read", owner: "event", channel: "channel.open", signal: "signal" }[def?.kind as string]
          expect([label, frame.t]).toEqual([label, expected])
          const payload = frame.t === "signal" ? frame.body : (frame as { params: unknown }).params
          expect([label, errs(`#/$defs/${c.message}`, payload)]).toEqual([label, []])
          if (frame.t === "channel.open") expect([label, frame.class]).toEqual([label, (def as { class?: string }).class])
          if (def && "existing" in def && def.existing) {
            const cloud = cloudOpByName.get(def.name)!
            expect([label, Exit.isSuccess(Schema.decodeUnknownExit(cloud.params as Schema.Codec<unknown, unknown>)(payload))]).toEqual([label, true])
          }
        }
        if (def?.kind !== "message") expect([label, schemas.validate(envelope, "", c.frame)]).toEqual([label, []])
      }
    })
  }
})

interface BinaryCase {
  readonly name: string
  readonly message?: string
  readonly hex: string
  readonly channel: number
  readonly seq: number
  readonly flags: Array<RecordFlagName>
  readonly payload: Record<string, Record<string, unknown>>
}
const binary = read<{ max_record: number; records: Array<BinaryCase>; streams: Array<{ name: string; hex: string; records: Array<string> }>; invalid_records: Array<{ name: string; hex: string; error: string }>; invalid_streams: Array<{ name: string; hex: string; error: string }> }>("fixtures/binary.json")

/** Builds the payload bytes from a vector's decoded fields (the encode direction). */
const encodePayload = (c: BinaryCase): Uint8Array | Record<string, unknown> => {
  const [kind, f] = Object.entries(c.payload)[0]!
  switch (kind) {
    case "terminal_input":
      return encodeTerminalInput({ kind: f.kind as "bytes" | "paste", data: bytes(f.data_hex as string) })
    case "terminal_output":
      return encodeTerminalOutput({ kind: f.kind as "bytes", generation: f.generation as number, offset: BigInt(f.offset as number), snapshotVersion: f.snapshot_version as number | undefined, data: bytes(f.data_hex as string) })
    case "credit":
      return creditRecord(c.channel, { ackSeq: BigInt(f.ack_seq as number), grantBytes: f.grant_bytes as number }).payload
    case "file_chunk":
      return encodeFileChunk({ offset: BigInt(f.offset as number), data: bytes(f.data_hex as string) })
    case "rd":
      return encodeRdStreamFrame({ type: f.type as 1, data: bytes(f.data_hex as string) })
    case "bytes":
      return bytes(f.data_hex as string)
    case "json":
      return f
    default:
      throw new Error(`unknown payload ${kind}`)
  }
}

describe("cmux.mobile/1 binary records", () => {
  it("max_record matches the codec", () => expect(binary.max_record).toBe(1 << 20))

  for (const c of binary.records) {
    it(`${c.name}: decodes to the listed fields and encodes back byte-exact`, () => {
      const r = decodeRecord(bytes(c.hex))
      expect([r.channel, r.seq, flagNames(r.flags)]).toEqual([c.channel, BigInt(c.seq), c.flags])
      const [kind, f] = Object.entries(c.payload)[0]!
      if (kind === "terminal_input") expect(decodeTerminalInput(r.payload)).toEqual({ kind: f.kind, data: bytes(f.data_hex as string) })
      if (kind === "terminal_output") {
        const o = decodeTerminalOutput(r.payload)
        expect([o.kind, o.generation, o.offset, o.snapshotVersion, hex(o.data)]).toEqual([f.kind, f.generation, BigInt(f.offset as number), f.snapshot_version, f.data_hex])
      }
      if (kind === "credit") expect(recordCredit(r)).toEqual({ ackSeq: BigInt(f.ack_seq as number), grantBytes: f.grant_bytes })
      if (kind === "file_chunk") expect(decodeFileChunk(r.payload)).toEqual({ offset: BigInt(f.offset as number), data: bytes(f.data_hex as string) })
      if (kind === "rd") expect(decodeRdStreamFrame(r.payload)).toEqual({ type: f.type, data: bytes(f.data_hex as string) })
      if (kind === "bytes") expect(hex(r.payload)).toBe(f.data_hex)
      if (kind === "json") {
        expect(recordJson(r)).toEqual(f)
        expect(encodeMobileJson(decodeMobileJson(f))).toEqual(f)
      }
      const payload = encodePayload(c)
      const record: StreamRecord = payload instanceof Uint8Array
        ? { channel: c.channel, seq: BigInt(c.seq), flags: flagsOf(c.flags), payload }
        : jsonRecord(c.channel, BigInt(c.seq), payload, c.flags.filter((n) => n !== "json"))
      expect(hex(encodeRecord(record))).toBe(c.hex)
      if (c.message) expect(mobileMessageByName.get(c.message)?.plane).toBe("stream")
    })
  }

  for (const s of binary.streams) {
    it(`${s.name}: deframes at every chunk size and frames back`, () => {
      const all = bytes(s.hex)
      for (let size = 1; size <= all.byteLength; size++) {
        const d = new RecordDeframer()
        const got: Array<string> = []
        for (let at = 0; at < all.byteLength; at += size) got.push(...d.push(all.subarray(at, at + size)).map((r) => hex(encodeRecord(r))))
        expect(got).toEqual(s.records)
      }
      expect(s.records.map((h) => hex(frameRecord(decodeRecord(bytes(h))))).join("")).toBe(s.hex)
    })
  }

  for (const c of binary.invalid_records) {
    it(`refuses ${c.name} (${c.error})`, () => {
      expect(() => decodeRecord(bytes(c.hex))).toThrow(expect.objectContaining({ reason: c.error, code: "proto.bad_record" }))
    })
  }

  for (const c of binary.invalid_streams) {
    it(`deframer refuses ${c.name} (${c.error}) and stays failed`, () => {
      const d = new RecordDeframer()
      expect(() => d.push(bytes(c.hex))).toThrow(expect.objectContaining({ reason: c.error }))
      expect(() => d.push(new Uint8Array(0))).toThrow(RecordError)
    })
  }
})

describe("schema checks are not vacuous", () => {
  it("refuses bad params, extra fields and a frame without its required fields", () => {
    const terminal = join(ROOT, "families/terminal.schema.json")
    expect(schemas.validate(terminal, "#/$defs/terminal.viewport", { t: "terminal.viewport", viewport: { cols: 1, rows: 1 } })).not.toEqual([])
    expect(schemas.validate(terminal, "#/$defs/terminal.presence", { t: "terminal.presence", visible: true, counts: true, extra: 1 })).not.toEqual([])
    expect(schemas.validate(join(ROOT, "families/host.schema.json"), "#/$defs/host.wake", { host: "mac" })).not.toEqual([])
    expect(schemas.validate(envelope, "", { t: "op", op: "host.wake", params: {} })).not.toEqual([])
  })
})
