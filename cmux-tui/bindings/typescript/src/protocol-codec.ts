import { CmuxProtocolError } from "./errors.js";
import {
  COMMAND_SCHEMAS,
  EVENT_METADATA,
  EVENT_SCHEMAS,
  TYPE_SCHEMAS,
} from "./generated/metadata.js";
import type {
  CmuxCommand,
  CmuxRequestParams,
  CmuxResponseDataFor,
  UnknownEvent,
} from "./generated/index.js";

type Schema = Readonly<Record<string, unknown>>;
type Direction = "decode" | "encode";

const UINT64_MAX = (1n << 64n) - 1n;
const INT64_MIN = -(1n << 63n);
const INT64_MAX = (1n << 63n) - 1n;

function failure(path: string, message: string): never {
  throw new CmuxProtocolError(`${path} ${message}`);
}

function schemaRecord(value: unknown, path: string): Schema {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    return failure(path, "schema is not an object");
  }
  return value as Schema;
}

function valueRecord(value: unknown, path: string): Record<string, unknown> {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    return failure(path, "must be an object");
  }
  return value as Record<string, unknown>;
}

function scalar(
  name: unknown,
  value: unknown,
  direction: Direction,
  path: string,
): unknown {
  switch (name) {
    case "string":
      if (typeof value !== "string") return failure(path, "must be a string");
      return value;
    case "boolean":
      if (typeof value !== "boolean") return failure(path, "must be a boolean");
      return value;
    case "float32":
    case "float64":
      if (typeof value !== "number" || !Number.isFinite(value)) {
        return failure(path, "must be a finite number");
      }
      return value;
    case "int32":
    case "uint16":
    case "uint32": {
      if (typeof value !== "number" || !Number.isSafeInteger(value)) {
        return failure(path, "must be a safe integer number");
      }
      const minimum = name === "int32" ? -2_147_483_648 : 0;
      const maximum = name === "uint16" ? 65_535 : name === "uint32" ? 4_294_967_295 : 2_147_483_647;
      if (value < minimum || value > maximum) return failure(path, `must be in ${name} range`);
      return value;
    }
    case "int64":
    case "uint64": {
      let exact: bigint;
      if (typeof value === "bigint") {
        exact = value;
      } else if (
        direction === "decode"
        && typeof value === "number"
        && Number.isSafeInteger(value)
      ) {
        exact = BigInt(value);
      } else {
        return failure(path, `must be a bigint ${name}`);
      }
      const minimum = name === "uint64" ? 0n : INT64_MIN;
      const maximum = name === "uint64" ? UINT64_MAX : INT64_MAX;
      if (exact < minimum || exact > maximum) return failure(path, `must be in ${name} range`);
      return exact;
    }
    default:
      return failure(path, `uses unknown scalar ${String(name)}`);
  }
}

function opaqueJson(value: unknown, direction: Direction, path: string, depth = 0): unknown {
  if (depth > 256) return failure(path, "exceeds maximum JSON depth");
  if (
    value === null
    || typeof value === "string"
    || typeof value === "boolean"
    || typeof value === "bigint"
  ) {
    return value;
  }
  if (typeof value === "number") {
    if (!Number.isFinite(value)) return failure(path, "contains a non-finite number");
    if (direction === "encode" && Number.isInteger(value) && !Number.isSafeInteger(value)) {
      return failure(path, "contains an unsafe integer number; pass bigint");
    }
    return value;
  }
  if (Array.isArray(value)) {
    return value.map((entry, index) => opaqueJson(entry, direction, `${path}[${index}]`, depth + 1));
  }
  if (value && typeof value === "object") {
    return Object.fromEntries(
      Object.entries(value).map(([key, entry]) => [
        key,
        opaqueJson(entry, direction, `${path}.${key}`, depth + 1),
      ]),
    );
  }
  return failure(path, "contains a non-JSON value");
}

function transform(
  rawSchema: unknown,
  value: unknown,
  direction: Direction,
  path: string,
): unknown {
  const schema = schemaRecord(rawSchema, path);
  switch (schema.kind) {
    case "scalar":
      return scalar(schema.name, value, direction, path);
    case "literal":
      if (value !== schema.value) return failure(path, `must equal ${String(schema.value)}`);
      return value;
    case "enum": {
      const values = schema.values;
      if (!Array.isArray(values) || !values.includes(value)) {
        return failure(path, "is not an allowed enum value");
      }
      return value;
    }
    case "alias":
      return transform(schema.target, value, direction, path);
    case "ref": {
      const name = schema.name;
      if (typeof name !== "string" || !(name in TYPE_SCHEMAS)) {
        return failure(path, `references unknown type ${String(name)}`);
      }
      return transform(TYPE_SCHEMAS[name as keyof typeof TYPE_SCHEMAS], value, direction, path);
    }
    case "opaque_json":
      return opaqueJson(value, direction, path);
    case "array": {
      if (!Array.isArray(value)) return failure(path, "must be an array");
      return value.map((entry, index) => (
        transform(schema.items, entry, direction, `${path}[${index}]`)
      ));
    }
    case "map": {
      const record = valueRecord(value, path);
      return Object.fromEntries(
        Object.entries(record).map(([key, entry]) => [
          key,
          transform(schema.values, entry, direction, `${path}.${key}`),
        ]),
      );
    }
    case "object": {
      const record = valueRecord(value, path);
      const result: Record<string, unknown> = { ...record };
      const fields = schemaRecord(schema.fields, `${path} fields`);
      for (const [name, rawField] of Object.entries(fields)) {
        const field = schemaRecord(rawField, `${path}.${name}`);
        const present = Object.prototype.hasOwnProperty.call(record, name)
          && record[name] !== undefined;
        if (!present) {
          if (direction === "encode" && field.presence === "required") {
            return failure(`${path}.${name}`, "is required");
          }
          continue;
        }
        const entry = record[name];
        if (entry === null) {
          if (field.nullable !== true) return failure(`${path}.${name}`, "must not be null");
          result[name] = null;
          continue;
        }
        result[name] = transform(field.type, entry, direction, `${path}.${name}`);
      }
      return result;
    }
    case "tagged_union": {
      const record = valueRecord(value, path);
      if (typeof schema.tag !== "string") return failure(path, "has an invalid union tag");
      const variants = schemaRecord(schema.variants, path);
      const selected = record[schema.tag];
      if (typeof selected !== "string" || !(selected in variants)) {
        return failure(`${path}.${schema.tag}`, "is not a known union variant");
      }
      return transform(variants[selected], value, direction, path);
    }
    case "untagged_union": {
      if (!Array.isArray(schema.variants)) return failure(path, "has invalid union variants");
      const errors: string[] = [];
      for (const variant of schema.variants) {
        try {
          return transform(variant, value, direction, path);
        } catch (error) {
          errors.push((error as Error).message);
        }
      }
      return failure(path, `does not match any union variant (${errors.join("; ")})`);
    }
    default:
      return failure(path, `uses unsupported schema kind ${String(schema.kind)}`);
  }
}

/** Validates and normalizes one generated command parameter object for sending. */
export function encodeCommandParams<C extends CmuxCommand>(
  command: C,
  params: CmuxRequestParams<C>,
): CmuxRequestParams<C> {
  const entry = COMMAND_SCHEMAS[command];
  if (!entry) return failure(String(command), "is not a known command");
  return transform(entry.request, params, "encode", `${command} request`) as CmuxRequestParams<C>;
}

/** Converts all uint64 fields in a known command result to bigint. */
export function decodeCommandResult<C extends CmuxCommand>(
  command: C,
  value: unknown,
): CmuxResponseDataFor<C> {
  const entry = COMMAND_SCHEMAS[command];
  if (!entry) return failure(String(command), "is not a known command");
  return transform(entry.result, value, "decode", `${command} result`) as CmuxResponseDataFor<C>;
}

/** Converts uint64 fields for known events while preserving unknown future events. */
export function decodeProtocolEvent(value: unknown): UnknownEvent {
  const record = valueRecord(value, "event");
  if (typeof record.event !== "string") return failure("event.event", "must be a string");
  if (!(record.event in EVENT_METADATA) || !(record.event in EVENT_SCHEMAS)) {
    return record as UnknownEvent;
  }
  const name = record.event as keyof typeof EVENT_METADATA;
  if (EVENT_METADATA[name].emission !== "emitted") {
    return record as UnknownEvent;
  }
  return transform(EVENT_SCHEMAS[name], record, "decode", `event ${name}`) as UnknownEvent;
}
