const DEFAULT_MAX_DEPTH = 256;

/**
 * Parses protocol JSON without rounding integers outside JavaScript's safe
 * range. Small integers remain numbers; large integers become bigint values.
 */
export function parseWireJson(text: string, maxDepth = DEFAULT_MAX_DEPTH): unknown {
  class Parser {
    private offset = 0;

    parse(): unknown {
      const value = this.value(0);
      this.whitespace();
      if (this.offset !== text.length) this.invalid("unexpected trailing data");
      return value;
    }

    private value(depth: number): unknown {
      if (depth > maxDepth) this.invalid(`JSON nesting exceeds ${maxDepth}`);
      this.whitespace();
      const current = text[this.offset];
      if (current === '"') return this.string();
      if (current === "{") return this.object(depth + 1);
      if (current === "[") return this.array(depth + 1);
      if (current === "t") return this.keyword("true", true);
      if (current === "f") return this.keyword("false", false);
      if (current === "n") return this.keyword("null", null);
      if (current === "-" || (current >= "0" && current <= "9")) return this.number();
      return this.invalid("expected a JSON value");
    }

    private object(depth: number): Record<string, unknown> {
      this.offset += 1;
      const result: Record<string, unknown> = {};
      this.whitespace();
      if (text[this.offset] === "}") {
        this.offset += 1;
        return result;
      }
      for (;;) {
        this.whitespace();
        if (text[this.offset] !== '"') this.invalid("expected an object key");
        const key = this.string();
        this.whitespace();
        if (text[this.offset] !== ":") this.invalid("expected ':' after an object key");
        this.offset += 1;
        const value = this.value(depth);
        if (Object.prototype.hasOwnProperty.call(result, key)) {
          this.invalid(`duplicate object key ${JSON.stringify(key)}`);
        }
        Object.defineProperty(result, key, {
          value,
          writable: true,
          enumerable: true,
          configurable: true,
        });
        this.whitespace();
        const separator = text[this.offset];
        if (separator === "}") {
          this.offset += 1;
          return result;
        }
        if (separator !== ",") this.invalid("expected ',' or '}'");
        this.offset += 1;
      }
    }

    private array(depth: number): unknown[] {
      this.offset += 1;
      const result: unknown[] = [];
      this.whitespace();
      if (text[this.offset] === "]") {
        this.offset += 1;
        return result;
      }
      for (;;) {
        result.push(this.value(depth));
        this.whitespace();
        const separator = text[this.offset];
        if (separator === "]") {
          this.offset += 1;
          return result;
        }
        if (separator !== ",") this.invalid("expected ',' or ']'");
        this.offset += 1;
      }
    }

    private string(): string {
      const start = this.offset;
      this.offset += 1;
      let escaped = false;
      while (this.offset < text.length) {
        const character = text[this.offset];
        this.offset += 1;
        if (escaped) {
          escaped = false;
          continue;
        }
        if (character === "\\") {
          escaped = true;
          continue;
        }
        if (character === '"') {
          try {
            return JSON.parse(text.slice(start, this.offset)) as string;
          } catch {
            return this.invalid("invalid JSON string");
          }
        }
      }
      return this.invalid("unterminated JSON string");
    }

    private number(): number | bigint {
      const source = text.slice(this.offset);
      const match = /^-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?/.exec(source);
      if (!match) return this.invalid("invalid JSON number");
      const token = match[0];
      this.offset += token.length;
      if (!token.includes(".") && !token.includes("e") && !token.includes("E")) {
        const exact = BigInt(token);
        if (
          exact > BigInt(Number.MAX_SAFE_INTEGER)
          || exact < BigInt(Number.MIN_SAFE_INTEGER)
        ) {
          return exact;
        }
      }
      const value = Number(token);
      if (!Number.isFinite(value)) return this.invalid("non-finite JSON number");
      return value;
    }

    private keyword<T>(word: string, value: T): T {
      if (text.slice(this.offset, this.offset + word.length) !== word) {
        return this.invalid(`expected '${word}'`);
      }
      this.offset += word.length;
      return value;
    }

    private whitespace(): void {
      while (
        text[this.offset] === " "
        || text[this.offset] === "\t"
        || text[this.offset] === "\r"
        || text[this.offset] === "\n"
      ) {
        this.offset += 1;
      }
    }

    private invalid(message: string): never {
      throw new SyntaxError(`${message} at byte ${this.offset}`);
    }
  }

  if (!Number.isSafeInteger(maxDepth) || maxDepth < 1) {
    throw new RangeError("maxDepth must be a positive safe integer");
  }
  return new Parser().parse();
}

/**
 * Serializes bigint values as exact JSON integer tokens and rejects unsafe
 * number integers before they can be silently rounded.
 */
export function stringifyWireJson(value: unknown, maxDepth = DEFAULT_MAX_DEPTH): string {
  const active = new Set<object>();

  const encode = (item: unknown, depth: number, arrayItem: boolean): string | undefined => {
    if (depth > maxDepth) throw new TypeError(`JSON nesting exceeds ${maxDepth}`);
    if (item === null) return "null";
    if (typeof item === "string" || typeof item === "boolean") return JSON.stringify(item);
    if (typeof item === "bigint") return item.toString(10);
    if (typeof item === "number") {
      if (!Number.isFinite(item)) throw new TypeError("cannot serialize a non-finite number");
      if (Number.isInteger(item) && !Number.isSafeInteger(item)) {
        throw new TypeError("cannot serialize an unsafe integer number; pass bigint");
      }
      return JSON.stringify(item);
    }
    if (typeof item === "undefined" || typeof item === "function" || typeof item === "symbol") {
      return arrayItem ? "null" : undefined;
    }
    if (typeof item !== "object") throw new TypeError(`unsupported JSON value: ${typeof item}`);
    if (active.has(item)) throw new TypeError("cannot serialize a cyclic object");
    active.add(item);
    try {
      if (Array.isArray(item)) {
        return `[${item.map((entry) => encode(entry, depth + 1, true) ?? "null").join(",")}]`;
      }
      const fields: string[] = [];
      for (const [key, entry] of Object.entries(item)) {
        const encoded = encode(entry, depth + 1, false);
        if (encoded !== undefined) fields.push(`${JSON.stringify(key)}:${encoded}`);
      }
      return `{${fields.join(",")}}`;
    } finally {
      active.delete(item);
    }
  };

  if (!Number.isSafeInteger(maxDepth) || maxDepth < 1) {
    throw new RangeError("maxDepth must be a positive safe integer");
  }
  const encoded = encode(value, 0, false);
  if (encoded === undefined) throw new TypeError("top-level value is not valid JSON");
  return encoded;
}
