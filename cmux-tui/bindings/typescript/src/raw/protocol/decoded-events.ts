import type {
  BrowserStateEvent,
  FrameEvent,
  KnownBrowserAttachEvent,
  KnownByteAttachEvent,
  OutputEvent,
  ResizedEvent,
  UnknownEvent,
  VtStateEvent,
} from "../generated/index.js";

/** Initial VT replay after browser-safe base64 decoding. */
export type DecodedVtStateEvent = Omit<VtStateEvent, "data"> & {
  data: Uint8Array;
};

/** Live PTY output after browser-safe base64 decoding. */
export type DecodedOutputEvent = Omit<OutputEvent, "data"> & {
  data: Uint8Array;
};

/** Replacement VT replay after browser-safe base64 decoding. */
export type DecodedResizedEvent = Omit<ResizedEvent, "data" | "replay"> & {
  data: Uint8Array;
  /** @deprecated Use data. */
  replay: Uint8Array;
};

type OtherDecodedAttachEvent = Exclude<
  KnownByteAttachEvent | KnownBrowserAttachEvent,
  VtStateEvent | OutputEvent | ResizedEvent
>;

/** Byte/browser attach events yielded by CmuxClient.attachSurface(). */
export type DecodedAttachEvent =
  | DecodedVtStateEvent
  | DecodedOutputEvent
  | DecodedResizedEvent
  | OtherDecodedAttachEvent
  | UnknownEvent;

export type DecodedBrowserStateEvent = BrowserStateEvent;
export type DecodedBrowserFrameEvent = FrameEvent;
