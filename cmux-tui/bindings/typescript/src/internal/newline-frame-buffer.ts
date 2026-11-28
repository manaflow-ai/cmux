import { Buffer } from "node:buffer";
import { CmuxConnectionError } from "../errors.js";

export interface NewlineFrameBufferInstrumentation {
  readonly scanned?: (bytes: number) => void;
  readonly retainedCopied?: (bytes: number) => void;
  readonly concatenated?: (bytes: number) => void;
  readonly retained?: (bytes: number, capacity: number) => void;
}

/** @internal Incremental bounded decoder for newline-delimited UTF-8 frames. */
export class NewlineFrameBuffer {
  private readonly chunks: Buffer[] = [];
  private readonly decoder = new TextDecoder("utf-8", { fatal: true });
  private frameBytes = 0;
  private retainedCapacity = 0;
  private stopped = false;

  constructor(
    private readonly maximumFrameBytes: number,
    private readonly onFrame: (frame: string) => void,
    private readonly onError: (error: Error) => void,
    private readonly instrumentation?: NewlineFrameBufferInstrumentation,
  ) {}

  push(chunk: Buffer): void {
    if (this.stopped) return;
    let offset = 0;
    while (offset < chunk.byteLength) {
      const newline = chunk.indexOf(0x0a, offset);
      if (newline < 0) {
        this.instrumentation?.scanned?.(chunk.byteLength - offset);
        this.appendRetained(chunk.subarray(offset));
        return;
      }

      this.instrumentation?.scanned?.(newline - offset + 1);
      if (!this.appendTransient(chunk.subarray(offset, newline))) return;
      const bytes = this.takeFrame();
      let frame: string;
      try {
        frame = this.decoder.decode(bytes);
      } catch {
        this.fail(new CmuxConnectionError("inbound message is not valid UTF-8"));
        return;
      }
      if (frame.trim() !== "") this.onFrame(frame);
      if (this.stopped) return;
      offset = newline + 1;
    }
  }

  dispose(): void {
    this.stopped = true;
    this.release();
  }

  /** Discard an incomplete frame while keeping the decoder usable. */
  reset(): void {
    if (this.stopped) return;
    this.release();
  }

  private appendTransient(chunk: Buffer): boolean {
    if (!this.checkFrameSize(chunk.byteLength)) return false;
    if (chunk.byteLength > 0) this.chunks.push(chunk);
    this.frameBytes += chunk.byteLength;
    return true;
  }

  private appendRetained(chunk: Buffer): boolean {
    if (!this.checkFrameSize(chunk.byteLength)) return false;
    if (chunk.byteLength > 0) {
      const owned = Buffer.allocUnsafeSlow(chunk.byteLength);
      chunk.copy(owned);
      this.instrumentation?.retainedCopied?.(chunk.byteLength);
      this.chunks.push(owned);
      this.retainedCapacity += owned.buffer.byteLength;
    }
    this.frameBytes += chunk.byteLength;
    this.reportRetained();
    return true;
  }

  private checkFrameSize(additionalBytes: number): boolean {
    if (additionalBytes <= this.maximumFrameBytes - this.frameBytes) return true;
    this.fail(
      new CmuxConnectionError(
        `inbound message exceeds ${this.maximumFrameBytes} bytes`,
      ),
    );
    return false;
  }

  private release(): void {
    this.chunks.length = 0;
    this.frameBytes = 0;
    this.retainedCapacity = 0;
    this.reportRetained();
  }

  private reportRetained(): void {
    this.instrumentation?.retained?.(this.frameBytes, this.retainedCapacity);
  }

  private takeFrame(): Buffer {
    let frame: Buffer;
    if (this.chunks.length === 0) {
      frame = Buffer.alloc(0);
    } else if (this.chunks.length === 1) {
      frame = this.chunks[0]!;
    } else {
      this.instrumentation?.concatenated?.(this.frameBytes);
      frame = Buffer.concat(this.chunks, this.frameBytes);
    }
    this.release();
    return frame;
  }

  private fail(error: Error): void {
    this.stopped = true;
    this.release();
    this.onError(error);
  }
}
