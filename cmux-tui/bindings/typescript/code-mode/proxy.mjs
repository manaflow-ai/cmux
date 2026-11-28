import { createConnection, createServer } from "node:net";

const [targetPath, listenPath, catalogPath] = Bun.argv.slice(2);
if (!targetPath || !listenPath || !catalogPath) throw new Error("code-mode proxy needs target, listen, and catalog paths");
const catalog = await Bun.file(catalogPath).json();
const operations = catalog.operations ?? {};
const MAX_IN_FLIGHT_PER_CONNECTION = 64;
const MAX_IN_FLIGHT_GLOBAL = 256;
let globalInFlight = 0;

function allowed(message) {
  return message?.protocol === "cmux.protocol/2"
    && message.type === "request"
    && typeof message.id === "string"
    && typeof message.operation === "string"
    && Object.hasOwn(operations, message.operation)
    && operations[message.operation].class !== "local"
    && (operations[message.operation].class !== "mutation" || typeof message.idempotency_key === "string");
}

const server = createServer((client) => {
  const upstream = createConnection(targetPath);
  let pending = Buffer.alloc(0);
  let upstreamPending = Buffer.alloc(0);
  const inFlight = new Set();
  let closed = false;
  const finish = () => {
    if (closed) return;
    closed = true;
    globalInFlight -= inFlight.size;
    inFlight.clear();
    client.destroy();
    upstream.destroy();
  };
  const reject = () => finish();
  const complete = (id) => {
    if (typeof id === "string" && inFlight.delete(id)) globalInFlight -= 1;
  };
  client.on("data", (chunk) => {
    pending = Buffer.concat([pending, chunk]);
    if (pending.length > 4 * 1024 * 1024) return reject();
    while (true) {
      const end = pending.indexOf(10);
      if (end < 0) return;
      const line = pending.subarray(0, end);
      pending = pending.subarray(end + 1);
      let message;
      try { message = JSON.parse(line); } catch { return reject(); }
      if (!allowed(message)) return reject();
      if (inFlight.size >= MAX_IN_FLIGHT_PER_CONNECTION
        || globalInFlight >= MAX_IN_FLIGHT_GLOBAL
        || inFlight.has(message.id)) return reject();
      inFlight.add(message.id);
      globalInFlight += 1;
      upstream.write(line);
      upstream.write("\n");
    }
  });
  upstream.on("data", (chunk) => {
    upstreamPending = Buffer.concat([upstreamPending, chunk]);
    while (true) {
      const end = upstreamPending.indexOf(10);
      if (end < 0) break;
      const line = upstreamPending.subarray(0, end);
      upstreamPending = upstreamPending.subarray(end + 1);
      try {
        const message = JSON.parse(line);
        if (message?.type === "response" || message?.type === "stream_end") complete(message.id);
      } catch {
        // Preserve the upstream bytes. The cmux client owns response validation.
      }
    }
    client.write(chunk);
  });
  client.on("close", finish);
  upstream.on("close", finish);
  client.on("error", reject);
  upstream.on("error", reject);
});
server.listen(listenPath);
