interface NodeBufferValue {
  readonly length: number;
  readonly [index: number]: number;
  toString(encoding: "base64"): string;
}

interface NodeBufferConstructor {
  from(value: Uint8Array): NodeBufferValue;
  from(value: string, encoding: "base64"): NodeBufferValue;
}

function nodeBuffer(): NodeBufferConstructor | undefined {
  return (globalThis as typeof globalThis & { Buffer?: NodeBufferConstructor }).Buffer;
}

/** Decodes standard base64 without requiring Node's `Buffer`. */
export function decodeBase64(value: string): Uint8Array {
  if (typeof globalThis.atob === "function") {
    const decoded = globalThis.atob(value);
    const bytes = new Uint8Array(decoded.length);
    for (let index = 0; index < decoded.length; index += 1) bytes[index] = decoded.charCodeAt(index);
    return bytes;
  }

  const Buffer = nodeBuffer();
  if (!Buffer) throw new Error("base64 decoding is not available in this runtime");
  const decoded = Buffer.from(value, "base64");
  const bytes = new Uint8Array(decoded.length);
  for (let index = 0; index < decoded.length; index += 1) bytes[index] = decoded[index];
  return bytes;
}

/** Encodes bytes as standard base64 without requiring Node's `Buffer`. */
export function encodeBase64(value: Uint8Array): string {
  if (typeof globalThis.btoa === "function") {
    let binary = "";
    const chunkSize = 0x8000;
    for (let offset = 0; offset < value.length; offset += chunkSize) {
      const chunk = value.subarray(offset, Math.min(offset + chunkSize, value.length));
      for (const byte of chunk) binary += String.fromCharCode(byte);
    }
    return globalThis.btoa(binary);
  }

  const Buffer = nodeBuffer();
  if (!Buffer) throw new Error("base64 encoding is not available in this runtime");
  return Buffer.from(value).toString("base64");
}
