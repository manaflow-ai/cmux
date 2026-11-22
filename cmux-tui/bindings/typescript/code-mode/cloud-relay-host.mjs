import { readFile } from "node:fs/promises";
import { createCloudBroker, serveCloudRelay } from "./cloud-relay.mjs";
const [socketPath, catalogPath, relayCatalogPath] = process.argv.slice(2);
if (!socketPath || !catalogPath) throw new Error("cloud relay host needs socket and catalog paths");
const catalog = JSON.parse(await readFile(catalogPath, "utf8"));
const relayCatalog = JSON.parse(await readFile(relayCatalogPath ?? new URL("../../../../backend/catalog/cloud-relay-operations.json", import.meta.url), "utf8"));
catalog.operations = { ...relayCatalog.operations, ...(catalog.operations ?? {}) };
const allowedOperations = new Set(Object.keys(relayCatalog.operations ?? {}));
for (const [name, descriptor] of Object.entries(catalog.operations ?? {})) {
  if (descriptor?.remote_relay === "allow") allowedOperations.add(name);
}
const broker = createCloudBroker({ apiUrl: process.env.CMUX_CLOUD_API_URL, bearerToken: process.env.CMUX_CLOUD_BEARER_TOKEN, catalog, allowedOperations });
const server = serveCloudRelay(socketPath, broker);
const close = () => server.close();
process.once("SIGTERM", close); process.once("SIGINT", close);
