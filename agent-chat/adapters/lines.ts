// Incremental NDJSON reader for a child process stdout stream.
export async function readLines(
  stream: ReadableStream<Uint8Array>,
  onLine: (line: string) => void,
  onClose?: () => void,
) {
  const decoder = new TextDecoder();
  let buf = "";
  const reader = stream.getReader();
  try {
    for (;;) {
      const { done, value: chunk } = await reader.read();
      if (done) break;
      if (!chunk?.byteLength) continue;
      buf += decoder.decode(chunk, { stream: true });
      let idx: number;
      while ((idx = buf.indexOf("\n")) >= 0) {
        const line = buf.slice(0, idx).trim();
        buf = buf.slice(idx + 1);
        if (line) onLine(line);
      }
    }
  } catch {
    // stream torn down with the process; fall through to onClose
  } finally {
    reader.releaseLock();
  }
  buf += decoder.decode(); // flush any buffered trailing multi-byte sequence
  if (buf.trim()) onLine(buf.trim());
  onClose?.();
}

export function tryParse(line: string): any | null {
  try {
    return JSON.parse(line);
  } catch {
    return null;
  }
}

export function truncate(s: string, n = 200): string {
  s = s.replace(/\s+/g, " ").trim();
  return s.length > n ? s.slice(0, n) + "…" : s;
}
