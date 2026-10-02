import { createConnection, createServer } from "node:net";

const [targetPath, listenPath, catalogPath] = Bun.argv.slice(2);
if (!targetPath || !listenPath || !catalogPath) throw new Error("code-mode proxy needs target, listen, and catalog paths");
const catalog = await Bun.file(catalogPath).json();
const operations = catalog.operations ?? {};

function allowed(message) {
  return message?.protocol === "cmux.protocol/2"
    && message.type === "request"
    && typeof message.operation === "string"
    && Object.hasOwn(operations, message.operation)
    && operations[message.operation].class !== "local"
    && (operations[message.operation].class !== "mutation" || typeof message.idempotency_key === "string");
}

const server = createServer((client) => {
  const upstream = createConnection(targetPath);
  let pending = Buffer.alloc(0);
  const reject = () => { client.destroy(); upstream.destroy(); };
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
      upstream.write(line);
      upstream.write("\n");
    }
  });
  upstream.on("data", (chunk) => client.write(chunk));
  client.on("close", () => upstream.destroy());
  upstream.on("close", () => client.destroy());
  client.on("error", reject);
  upstream.on("error", reject);
});
server.listen(listenPath);
