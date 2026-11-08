import assert from "node:assert/strict";
import test from "node:test";
import {
  CmuxAbortError,
  CmuxClient,
  parseWireJson,
  type BrowserStreamEvent,
  type JsonObject,
  type Transport,
  type Unsubscribe,
} from "cmux-sdk/raw";

class ConsumerTransport implements Transport {
  readonly sent: string[] = [];
  private readonly handlers = new Set<(json: string) => void>();

  send(json: string): void {
    this.sent.push(json);
    const request = parseWireJson(json) as JsonObject;
    const id = request.id;
    switch (request.cmd) {
      case "identify":
        this.emit(`{"id":${id},"ok":true,"data":{"app":"cmux-tui","version":"0.1.2","protocol":12,"session":"main","pid":1,"registry_id":"registry","generation":"generation","workspace_revision":1,"terminal_revision":1,"daemon_handoff":1}}`);
        break;
      case "read-screen":
        this.emit(`{"id":${id},"ok":true,"data":{"text":"ready"}}`);
        break;
      case "ids":
        this.emit(`{"id":${id},"ok":true,"data":{"ids":[{"kind":"surface","id":18446744073709551615,"short_id":"ffffff"}]}}`);
        break;
      case "attach-surface":
        this.emit('{"event":"browser-state","surface":18446744073709551615,"cols":80,"rows":24,"url":"https://example.com","title":"Example","status":"live","error":null,"frames_stalled":false,"frame":null}');
        this.emit('{"event":"future-browser-event","surface":18446744073709551615,"seq":18446744073709551615,"nested":{"revision":18446744073709551614},"optional":null}');
        this.emit(`{"id":${id},"ok":true,"data":{}}`);
        break;
      default:
        throw new Error(`unexpected command ${String(request.cmd)}`);
    }
  }

  onMessage(handler: (json: string) => void): Unsubscribe {
    this.handlers.add(handler);
    return () => this.handlers.delete(handler);
  }

  onClose(): Unsubscribe { return () => undefined; }
  onError(): Unsubscribe { return () => undefined; }
  close(): void {}

  private emit(json: string): void {
    for (const handler of this.handlers) handler(json);
  }
}

test("published browser entry preserves uint64 values at the package boundary", async () => {
  const maximum = 18_446_744_073_709_551_615n;
  const transport = new ConsumerTransport();
  const client = new CmuxClient({ transport });

  await client.identify();
  assert.equal((await client.request({ cmd: "read-screen", surface: maximum })).text, "ready");
  assert.match(transport.sent[1] ?? "", /"surface":18446744073709551615/);
  assert.equal((await client.request({ cmd: "ids" })).ids[0]?.id, maximum);

  const browser = await client.attachBrowserSurface(maximum);
  const browserEvent: BrowserStreamEvent = await browser.next();
  assert.equal(browserEventLabel(browserEvent), "state:https://example.com");
  const futureEvent: BrowserStreamEvent = await browser.next();
  assert.equal(browserEventLabel(futureEvent), "unknown:future-browser-event");
  if (futureEvent.event === "unknown") {
    assert.equal(futureEvent.raw.surface, maximum);
    assert.equal(futureEvent.raw.seq, maximum);
    assert.deepEqual(futureEvent.raw.nested, { revision: maximum - 1n });
    assert.equal(futureEvent.raw.optional, null);
  }
  const abort = new AbortController();
  const pending = browser.next({ signal: abort.signal });
  abort.abort();
  await assert.rejects(() => pending, CmuxAbortError);
  browser.close();

  await client.close();
});

function browserEventLabel(event: BrowserStreamEvent): string {
  switch (event.event) {
    case "browser-state": return `state:${event.url}`;
    case "frame": return `frame:${event.seq}`;
    case "detached": return `detached:${event.surface}`;
    case "notification": return `notification:${event.notification}`;
    case "overflow": return `overflow:${event.error}`;
    case "scroll-changed": return `scroll:${event.offset}`;
    case "unknown": return `unknown:${event.wireEvent}`;
    default: {
      const exhaustive: never = event;
      return exhaustive;
    }
  }
}
